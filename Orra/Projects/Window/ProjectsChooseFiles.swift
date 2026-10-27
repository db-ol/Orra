import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the sheet that chooses files for an email holds: the files the index lists in the
/// folders of every project, the paths of the files the saved explanation holds, the search,
/// the ticks, a dropped file that waits for the index of the folder the user added for it, the
/// line of the last action, and the save, see ProjectsChooseFiles.
///
/// It reads the index's list of files, never the disk: a file dropped from Finder is placed by
/// its path alone against the real paths of the projects' folders, see
/// ProjectsEmailFiles.place(of:in:), and nothing opens or looks it up. A file outside every
/// folder can only bring its folder into a project, for all of that project's mail, as Edit
/// Project does. Nothing here logs.
@Observable
final class ProjectsFileChoice {
    /// A file of the list, under the project whose section shows it.
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        var project: UUID
        var url: URL
        /// Nil for a chosen file the index does not list.
        var modified: Date?
        var reading: FolderIndex.ListedFile.Reading?
        var isInExplanation = false

        var id: String { url.path }
    }

    /// A section of the list: a project's files, or the chosen files the index lacks.
    nonisolated struct Section: Identifiable, Equatable, Sendable {
        nonisolated enum Kind: Hashable, Sendable {
            case project(UUID)
            case notRead
        }

        var kind: Kind
        var title: String
        /// The files it shows: the first `sectionLimit` that match, and every chosen one.
        var rows: [Row]
        /// The files of it that match the search, also those it does not show.
        var total: Int
        /// Whether the index works on the project's folders now.
        var isIndexing = false

        var id: Kind { kind }
    }

    /// The line of the last action, which VoiceOver reads as it shows.
    nonisolated enum Notice: Equatable, Sendable {
        /// A seventh tick, which stays off.
        case limit
        /// A dropped file the index lists, now ticked, by its name.
        case chosen(String)
        /// A dropped file inside a project folder that the index does not list.
        case notRead(String)
        /// A dropped file outside every project folder, whose folder the user may add.
        case outside(URL)
        /// The folder added for a dropped file, which the index reads now.
        case reading(String)
        /// The folder added does not hold the dropped file.
        case notInFolder(String)
        case refused(FolderWalk.Refusal)
        /// The project could not be saved with the folder.
        case projectNotSaved
        /// The choice could not be saved.
        case notSaved
    }

    /// The files a section shows at most, besides the chosen ones (a guess).
    nonisolated static let sectionLimit = 200

    let email: MailStore.Listed
    @ObservationIgnored private let runtime: ProjectsRuntime
    @ObservationIgnored private let emailModel: ProjectsEmailModel
    /// The files the index lists, every project's.
    private(set) var listed: [FolderIndex.ListedFile] = []
    /// The real paths of each project's folders, for the folder lines and the drops.
    private(set) var roots: [UUID: ProjectsEmailFiles.Roots] = [:]
    /// The paths of the files whose excerpts the saved explanation holds.
    private(set) var inExplanation: Set<String> = []
    private(set) var isLoaded = false
    var query = ""
    /// The files ticked, in the order of the ticks. Nothing is saved before Save or Explain.
    private(set) var ticks: [MailStore.ChosenFile] = []
    private(set) var notice: Notice?
    /// The path of a dropped file, lowercased, whose folder the user added, until the index
    /// lists it.
    private(set) var waiting: String?
    /// The row to show, after a drop or once a waiting file is read.
    private(set) var scrollTarget: String?
    private(set) var isSaving = false
    /// The files a section shows at most, `sectionLimit` in the app. Renders show fewer.
    var shownPerSection = ProjectsFileChoice.sectionLimit

    init(email: MailStore.Listed, runtime: ProjectsRuntime, emailModel: ProjectsEmailModel) {
        self.email = email
        self.runtime = runtime
        self.emailModel = emailModel
    }

    // MARK: Reading

    /// Reads the index's files and the projects' folders, and the first time the email's
    /// saved choice and the files of its saved explanation. Called when the sheet opens and
    /// again when an index's report changes, so a folder added from here shows its files.
    func load() async {
        let files = await runtime.projectFiles()
        var found: [UUID: ProjectsEmailFiles.Roots] = [:]
        for project in runtime.projectList {
            if let resolved = await runtime.folderRoots(of: project.id) {
                found[project.id] = resolved
            }
        }
        if !isLoaded {
            await emailModel.loadChoice()
            ticks = emailModel.chosenFiles
            let sources = await runtime.explanation(for: email.messageID)?.sources ?? [:]
            inExplanation = Set(sources.values.compactMap { source -> String? in
                guard case .file(let chunk, _) = source else { return nil }
                return chunk.file.path
            })
        }
        listed = files
        roots = found
        isLoaded = true
        takeWaitingFile()
    }

    /// The sections for the search as it is: the email's project first, then the other
    /// projects by name, each with its files that match, those of the saved explanation first
    /// and then the newest, then the chosen files the index lacks. A file in the folders of two
    /// projects shows once, under the email's project when it is one of them, else under the
    /// first of them by name. A project without files has no section, and while a search runs
    /// neither has one without a match.
    var sections: [Section] {
        Self.sections(
            listed: listed, projects: runtime.projectList, emailProject: email.project, inExplanation: inExplanation,
            ticks: ticks, query: query, indexing: Set(runtime.projectList.map(\.id).filter { runtime.indexReport($0)?.isIndexing == true }),
            limit: shownPerSection)
    }

    nonisolated static func sections(
        listed: [FolderIndex.ListedFile], projects: [Project], emailProject: UUID?, inExplanation: Set<String>,
        ticks: [MailStore.ChosenFile], query: String, indexing: Set<UUID>, limit: Int = sectionLimit
    ) -> [Section] {
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let order = projects.sorted { first, second in
            if first.id == emailProject { return second.id != emailProject }
            if second.id == emailProject { return false }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }.map(\.id)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Each path once, under the project that comes first.
        var byPath: [String: FolderIndex.ListedFile] = [:]
        for file in listed where names[file.project] != nil {
            let key = file.url.path.lowercased()
            if let held = byPath[key], rank[held.project, default: .max] <= rank[file.project, default: .max] { continue }
            byPath[key] = file
        }
        let ticked = Set(ticks.map { $0.path.lowercased() })
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        func matches(_ url: URL) -> Bool {
            !searching || url.lastPathComponent.localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var sections: [Section] = []
        for project in order {
            let files = byPath.values.filter { $0.project == project }
            guard !files.isEmpty else { continue }
            let rows = files.filter { matches($0.url) }.map { file in
                Row(project: project, url: file.url, modified: file.modified, reading: file.reading, isInExplanation: inExplanation.contains(file.url.path))
            }.sorted { first, second in
                if first.isInExplanation != second.isInExplanation { return first.isInExplanation }
                if first.modified != second.modified { return (first.modified ?? .distantPast) > (second.modified ?? .distantPast) }
                return first.url.path < second.url.path
            }
            guard !rows.isEmpty || !searching else { continue }
            let shown = Array(rows.prefix(limit)) + rows.dropFirst(limit).filter { ticked.contains($0.url.path.lowercased()) }
            let name = names[project] ?? ""
            sections.append(Section(
                kind: .project(project), title: project == emailProject ? ProjectsWindowText.emailsProject(name) : name,
                rows: shown, total: rows.count, isIndexing: indexing.contains(project)))
        }
        let missing = ticks.filter { byPath[$0.path.lowercased()] == nil }
            .map { Row(project: $0.project, url: URL(fileURLWithPath: $0.path)) }
            .filter { matches($0.url) }
        if !missing.isEmpty {
            sections.append(Section(kind: .notRead, title: String(localized: "Chosen Files Projects Has Not Read"), rows: missing, total: missing.count))
        }
        return sections
    }

    /// The folder line of a row: the project folder that holds it and the folders below it,
    /// as the list of an explanation's files writes it, or its folder with ~ while the
    /// project's folders are not read.
    func folder(of row: Row) -> String {
        guard let roots = roots[row.project] else {
            return ProjectsWindowText.folder(.outside(row.url.deletingLastPathComponent()))
        }
        return ProjectsWindowText.folder(ProjectsEmailFiles.place(of: row.url, in: roots))
    }

    // MARK: Ticking

    func isTicked(_ row: Row) -> Bool {
        ticks.contains { $0.path == row.url.path }
    }

    /// Ticks or unticks a file. A seventh tick stays off and says so.
    func toggle(_ row: Row) {
        if let index = ticks.firstIndex(where: { $0.path == row.url.path }) {
            ticks.remove(at: index)
            if notice == .limit {
                notice = nil
            }
            return
        }
        guard ticks.count < ExplainPrompt.chosenFileLimit else {
            notice = .limit
            return
        }
        ticks.append(MailStore.ChosenFile(project: row.project, path: row.url.path))
    }

    /// Return to Automatic Selection in the sheet: unticks every file. Save or Explain saves
    /// that.
    func untickAll() {
        ticks = []
        notice = nil
    }

    // MARK: Dropped files

    /// Files dragged onto the list from Finder, each placed by its path alone, never opened
    /// or looked up: a file the index lists is ticked and shown, one inside a project folder
    /// that the index does not list says so, and one outside every folder offers to add its
    /// folder to a project.
    func drop(_ urls: [URL]) {
        let every = Self.sections(listed: listed, projects: runtime.projectList, emailProject: email.project, inExplanation: inExplanation, ticks: [], query: "", indexing: [])
        for url in urls where url.isFileURL {
            let key = url.path.lowercased()
            if let row = every.lazy.flatMap(\.rows).first(where: { $0.url.path.lowercased() == key }) {
                query = ""
                if !isTicked(row) {
                    guard ticks.count < ExplainPrompt.chosenFileLimit else {
                        notice = .limit
                        continue
                    }
                    ticks.append(MailStore.ChosenFile(project: row.project, path: row.url.path))
                }
                notice = .chosen(row.url.lastPathComponent)
                scrollTarget = row.id
            } else if roots.values.contains(where: { roots in
                if case .outside = ProjectsEmailFiles.place(of: url, in: roots) { return false }
                return true
            }) {
                notice = .notRead(url.lastPathComponent)
            } else {
                notice = .outside(url)
            }
        }
    }

    /// Adds the folder the user picked in the open panel to a project, for all its mail, for
    /// a dropped file or with nil for Add a Folder: a folder that does not hold the dropped file
    /// is not added, and a refused one says why. The dropped file is ticked at once, and the
    /// sheet says so once the index lists it.
    func addFolder(_ folder: URL, to project: UUID, for dropped: URL?) async {
        if let dropped {
            guard case .inFolder = ProjectsEmailFiles.place(of: dropped, in: ProjectsEmailFiles.Roots(folders: [folder])) else {
                notice = .notInFolder(dropped.lastPathComponent)
                return
            }
        }
        switch await runtime.addFolder(folder, to: project) {
        case .refused(let refusal):
            notice = .refused(refusal)
        case .failed:
            notice = .projectNotSaved
        case .saved:
            guard let dropped else {
                notice = nil
                return
            }
            if !ticks.contains(where: { $0.path.lowercased() == dropped.path.lowercased() }) {
                guard ticks.count < ExplainPrompt.chosenFileLimit else {
                    notice = .limit
                    return
                }
                ticks.append(MailStore.ChosenFile(project: project, path: dropped.path))
            }
            waiting = dropped.path.lowercased()
            notice = .reading(dropped.lastPathComponent)
            takeWaitingFile()
        }
    }

    /// Once the index lists the dropped file that waits, its tick takes the path and the
    /// project the index gives, and the sheet says that it is chosen.
    private func takeWaitingFile() {
        guard let waiting, let file = listed.first(where: { $0.url.path.lowercased() == waiting }) else { return }
        self.waiting = nil
        if let index = ticks.firstIndex(where: { $0.path.lowercased() == waiting }) {
            ticks[index] = MailStore.ChosenFile(project: file.project, path: file.url.path)
        }
        notice = .chosen(file.url.lastPathComponent)
        scrollTarget = file.url.path
    }

    // MARK: Saving

    /// Saves the ticks as the email's choice, and says whether the store kept them. The
    /// sheet stays open with a line when it did not.
    func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }
        guard await emailModel.saveChoice(ticks) else {
            notice = .notSaved
            return false
        }
        return true
    }
}

/// Choose Files for This Email, a sheet of the Projects window: the files of every folder the
/// user added to a project, from the index, the email's project first and the other projects
/// under their names, searched by name, each with its folder, its kind, what Projects reads of
/// it and its date. The user ticks up to `ExplainPrompt.chosenFileLimit` of them for the email,
/// and Save keeps the choice for the next Explain or Explain Again, which Explain Again here
/// runs at once. A file outside the folders can only bring its folder into a project, through
/// the open panel, for all of the project's mail.
///
/// Names, folders, projects and the subject show as plain text. The title, the sections and
/// each row read as VoiceOver expects: headings, and one checkbox a file with its lines, its
/// project at the end.
struct ProjectsChooseFiles: View {
    let runtime: ProjectsRuntime
    let model: ProjectsWindowModel
    @State private var choice: ProjectsFileChoice
    @FocusState private var searchHasFocus: Bool
    /// The open panel that adds a folder to a project, while it shows.
    @State private var panel: Panel?
    @State private var showsPanel = false
    /// The sheet's height, for the footer: under the list, or at its end in a sheet too low
    /// for both, so the list keeps its rows.
    @State private var height: CGFloat = 560

    /// The lowest sheet whose footer stays under the list. In Spanish at 520 points wide,
    /// the header, the footer and the buttons in two rows take about 310 points, so a lower
    /// sheet would leave the list less than its 120 points, and some room is left for larger
    /// text.
    static let compactHeight: CGFloat = 470

    /// A folder to add to a project, with the dropped file it is for, if any.
    struct Panel: Equatable {
        var project: Project
        var dropped: URL?
    }

    /// Reads the files again when an index's report changes, such as after a folder was
    /// added, or the projects' folders do.
    private struct Reload: Hashable {
        var reports: [UUID: [Int]]
        var folders: [UUID: [Data]]
    }

    init(runtime: ProjectsRuntime, model: ProjectsWindowModel, email: MailStore.Listed) {
        self.init(runtime: runtime, model: model, choice: ProjectsFileChoice(email: email, runtime: runtime, emailModel: model.emailModel(for: email.messageID)))
    }

    /// The sheet with a model of its own, such as one a test filled.
    init(runtime: ProjectsRuntime, model: ProjectsWindowModel, choice: ProjectsFileChoice) {
        self.runtime = runtime
        self.model = model
        _choice = State(initialValue: choice)
    }

    private var email: MailStore.Listed {
        choice.email
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 10)
            Divider()
            list
                .frame(minHeight: 120)
            if !isCompact {
                Divider()
                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            Divider()
            buttons
                .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 380, idealHeight: 560)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .task(id: reload) {
            await choice.load()
        }
        .onAppear {
            searchHasFocus = true
        }
        .onChange(of: choice.notice) { _, notice in
            if let notice {
                AccessibilityNotification.Announcement(ProjectsWindowText.choiceNotice(notice)).post()
            }
        }
        .fileImporter(isPresented: $showsPanel, allowedContentTypes: [.folder]) { result in
            guard let panel, case .success(let folder) = result else { return }
            Task { await choice.addFolder(folder, to: panel.project.id, for: panel.dropped) }
        }
        .fileDialogDefaultDirectory(panel?.dropped?.deletingLastPathComponent())
        .fileDialogMessage(Text(verbatim: ProjectsWindowText.folderPanelMessage(panel?.project.name ?? "")))
        .fileDialogConfirmationLabel(Text("Add Folder"))
    }

    /// Whether the sheet is too low for the footer under the list.
    private var isCompact: Bool {
        height < Self.compactHeight
    }

    private var reload: Reload {
        var reports: [UUID: [Int]] = [:]
        var folders: [UUID: [Data]] = [:]
        for project in runtime.projectList {
            let report = runtime.indexReport(project.id)
            reports[project.id] = [report?.indexed ?? -1, report?.nameOnly ?? -1, report?.isIndexing == true ? 1 : 0, report?.recognitionLeft ?? 0]
            folders[project.id] = project.folders
        }
        return Reload(reports: reports, folders: folders)
    }

    // MARK: The header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose Files for This Email")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: email.subject)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            // The count goes under the field where they do not fit side by side.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    searchField
                        .frame(minWidth: 240)
                    count
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    searchField
                    count
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if choice.notice == .limit {
                Text(verbatim: ProjectsWindowText.choiceNotice(.limit))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        @Bindable var choice = choice
        return TextField("Search by File Name", text: $choice.query)
            .textFieldStyle(.roundedBorder)
            .focused($searchHasFocus)
    }

    private var count: some View {
        Text(verbatim: ProjectsWindowText.chosenCount(choice.ticks.count))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: The list

    private var list: some View {
        let sections = choice.sections
        let searching = !choice.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ScrollViewReader { scroller in
            List {
                // The line about a dropped file or an added folder, at the top of the list, so
                // it shows at the sheet's smallest size too.
                if let notice = choice.notice, notice != .limit {
                    noticeView(notice)
                        .id(Self.noticeRow)
                }
                if choice.isLoaded, sections.isEmpty {
                    Text(verbatim: searching ? ProjectsWindowText.noFileNameMatches(choice.query) : String(localized: "Your projects hold no files yet."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(sections) { section in
                    Section {
                        if section.isIndexing {
                            Text("Projects is still reading this project's folders.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if section.kind == .notRead {
                            Text("They may have moved or left your project folders, or Projects has not read them yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(section.rows) { row in
                            FileToggle(row: row, folder: choice.folder(of: row), project: projectName(row.project), isOn: Binding(
                                get: { choice.isTicked(row) },
                                set: { _ in choice.toggle(row) }))
                            .id(row.id)
                        }
                        if section.total > section.rows.count {
                            Text(verbatim: ProjectsWindowText.moreFiles(shown: min(section.total, choice.shownPerSection), total: section.total, searching: searching))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text(verbatim: section.title)
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                if isCompact {
                    footer
                        .padding(.vertical, 6)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                choice.drop(urls)
                return true
            }
            .onChange(of: choice.scrollTarget) { _, target in
                if let target {
                    withAnimation {
                        scroller.scrollTo(target, anchor: .center)
                    }
                }
            }
            .onChange(of: choice.notice) { _, notice in
                // A file that is chosen now shows its row instead.
                guard let notice, notice != .limit, choice.scrollTarget == nil || !Self.showsItsRow(notice) else { return }
                withAnimation {
                    scroller.scrollTo(Self.noticeRow, anchor: .top)
                }
            }
        }
    }

    /// The id of the row of the line about a dropped file or an added folder.
    private static let noticeRow = "notice"

    /// Whether a line comes with the row of the file it chose, which the list shows instead.
    private static func showsItsRow(_ notice: ProjectsFileChoice.Notice) -> Bool {
        if case .chosen = notice { return true }
        return false
    }

    private func projectName(_ id: UUID) -> String {
        runtime.projectList.first { $0.id == id }?.name ?? ""
    }

    /// One file as one checkbox: its name, its folder, and its kind with what Projects reads
    /// of it, its date and whether the saved explanation holds it, then its project for
    /// VoiceOver.
    struct FileToggle: View {
        let row: ProjectsFileChoice.Row
        let folder: String
        let project: String
        let isOn: Binding<Bool>

        var body: some View {
            let line = ProjectsWindowText.listedFile(kind: ProjectsWindowText.fileKind(row.url), reading: row.reading, modified: row.modified, inExplanation: row.isInExplanation)
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: folder)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: line)
                        .lineLimit(2)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(Text(verbatim: row.url.lastPathComponent))
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(Text(verbatim: [row.url.lastPathComponent, folder, line, ProjectsWindowText.inProject(project)].joined(separator: ", ")))
        }
    }

    // MARK: The footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Orra puts the passages of these files that best fit this email first, or a file's beginning, then adds what its own search finds. Of a file without text, the model gets only its name.")
                Group {
                    if email.isExplained {
                        Text("This choice is for this email only. Explain Again uses it.")
                    } else {
                        Text("This choice is for this email only. Explain uses it.")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // The button goes under the line where they do not fit side by side.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    dragLine
                    addFolder(for: nil)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    dragLine
                    addFolder(for: nil)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dragLine: some View {
        Text("Not listed? Drag the file here from Finder.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func noticeView(_ notice: ProjectsFileChoice.Notice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: ProjectsWindowText.choiceNotice(notice))
                .fixedSize(horizontal: false, vertical: true)
            if case .outside(let file) = notice {
                if runtime.projectList.isEmpty {
                    Text("Make a project with New Project… and add the folder there.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    addFolder(for: file)
                }
            }
        }
        .font(.callout)
    }

    /// Add a Folder to the email's project, or for an email without one a menu of the
    /// projects, which opens the open panel, in the folder of the dropped file when there is
    /// one. Nothing while Projects has no project.
    @ViewBuilder
    private func addFolder(for dropped: URL?) -> some View {
        let projects = runtime.projectList
        if let project = email.project.flatMap({ id in projects.first { $0.id == id } }) {
            Button {
                openPanel(Panel(project: project, dropped: dropped))
            } label: {
                Text(verbatim: dropped == nil ? ProjectsWindowText.addFolder(to: project.name) : ProjectsWindowText.addItsFolder(to: project.name))
                    .lineLimit(2)
            }
            .disabled(runtime.phase != .on)
        } else if !projects.isEmpty {
            Menu {
                ForEach(projects) { project in
                    Button {
                        openPanel(Panel(project: project, dropped: dropped))
                    } label: {
                        Text(verbatim: project.name)
                    }
                }
            } label: {
                if dropped == nil {
                    Text("Add a Folder to a Project")
                } else {
                    Text("Add Its Folder to a Project")
                }
            }
            .fixedSize()
            .disabled(runtime.phase != .on)
        }
    }

    private func openPanel(_ new: Panel) {
        panel = new
        showsPanel = true
    }

    // MARK: The buttons

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                returnButton
                Spacer()
                closingButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                returnButton
                HStack(spacing: 10) {
                    Spacer()
                    closingButtons
                }
            }
        }
    }

    private var returnButton: some View {
        Button("Return to Automatic Selection") {
            choice.untickAll()
        }
        .disabled(choice.ticks.isEmpty)
    }

    @ViewBuilder
    private var closingButtons: some View {
        Button("Cancel", role: .cancel) {
            model.choosingFiles = nil
        }
        .keyboardShortcut(.cancelAction)
        Button("Save") {
            Task {
                guard await choice.save() else { return }
                // The line under Explain says what the next explanation uses, once.
                if let note = model.emailModel(for: email.messageID).choiceNote {
                    AccessibilityNotification.Announcement(ProjectsWindowText.choiceNote(note)).post()
                }
                model.choosingFiles = nil
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(choice.isSaving || runtime.phase != .on)
        Button {
            Task {
                guard await choice.save() else { return }
                model.explainFromTheSheet(email.messageID)
            }
        } label: {
            if email.isExplained {
                Text("Explain Again")
            } else {
                Text("Explain")
            }
        }
        .disabled(choice.isSaving || !canExplain)
    }

    /// Whether Explain or Explain Again can run, as in the email's header: not while the email
    /// is explained or its draft changes, not for an email without text, and only while
    /// Projects is on.
    private var canExplain: Bool {
        model.explaining[email.messageID] != .explaining && !model.emailModel(for: email.messageID).isBusy
            && ProjectsWindowText.noText(email) == nil && runtime.phase == .on
    }
}
