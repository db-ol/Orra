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
/// Project does. The files are read and ordered off the main actor, since a project may hold
/// thousands. Nothing here logs.
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

    /// The files the index lists as the sheet orders them before a search, see
    /// `arrange(_:order:inExplanation:)`.
    nonisolated struct Listing: Sendable {
        /// A project's files: those of the saved explanation first, then the newest.
        nonisolated struct Files: Sendable {
            var project: UUID
            var rows: [Row]
        }

        /// The projects with files, the email's project first, then the others by name.
        var projects: [Files] = []
        /// Every file by its path without case, under the project whose section shows it.
        var byPath: [String: Row] = [:]
    }

    /// The line of the last action, which VoiceOver reads as it shows.
    nonisolated enum Notice: Equatable, Sendable {
        /// A seventh tick, which stays off, or a dropped file that could not be ticked, for
        /// which no folder is offered.
        case limit
        /// A dropped file the index lists, now ticked, by its name.
        case chosen(String)
        /// A dropped file inside a project folder that the index does not list.
        case notRead(String)
        /// A dropped folder, by its name, which is no file to choose.
        case folder(String)
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

    /// The files a section shows at most, besides the chosen ones. Search finds the others.
    nonisolated static let sectionLimit = 200
    /// How often the sheet reads the files again while an index reads a project's folders,
    /// such as a folder added from the sheet.
    nonisolated static let followInterval: Duration = .seconds(3)

    let email: MailStore.Listed
    @ObservationIgnored private let runtime: ProjectsRuntime
    @ObservationIgnored private let emailModel: ProjectsEmailModel
    /// The files the index lists, every project's, in the sheet's order.
    private(set) var listing = Listing()
    /// Counts the reads of `load()`, so a read that a newer one overtook keeps nothing.
    @ObservationIgnored private var loads = 0
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
    /// saved choice and the files of its saved explanation, then orders the files off the main
    /// actor. Called when the sheet opens, and again when an index starts or ends reading a
    /// project's folders and every `followInterval` while it reads, so a folder added from here
    /// shows its files. Only the newest of reads that overlap keeps what it read, and the ticks
    /// the user made stay.
    func load() async {
        loads += 1
        let load = loads
        let projects = runtime.projectList
        let files = await runtime.projectFiles()
        var found: [UUID: ProjectsEmailFiles.Roots] = [:]
        for project in projects {
            if let resolved = await runtime.folderRoots(of: project.id) {
                found[project.id] = resolved
            }
        }
        var saved: (ticks: [MailStore.ChosenFile], inExplanation: Set<String>)?
        if !isLoaded {
            await emailModel.loadChoice()
            let sources = await runtime.explanation(for: email.messageID)?.sources ?? [:]
            saved = (emailModel.chosenFiles, Set(sources.values.compactMap { source -> String? in
                guard case .file(let chunk, _) = source else { return nil }
                return chunk.file.path
            }))
        }
        let listing = await Self.arrange(files, order: Self.order(of: projects, emailProject: email.project), inExplanation: saved?.inExplanation ?? inExplanation)
        // A newer read overtook this one, or the sheet closed.
        guard load == loads, !Task.isCancelled else { return }
        if let saved, !isLoaded {
            ticks = saved.ticks
            inExplanation = saved.inExplanation
        }
        self.listing = listing
        roots = found
        isLoaded = true
        takeWaitingFile()
    }

    /// The order of the projects' sections: the email's project first, then the others by
    /// name.
    nonisolated static func order(of projects: [Project], emailProject: UUID?) -> [UUID] {
        projects.sorted { first, second in
            if first.id == emailProject { return second.id != emailProject }
            if second.id == emailProject { return false }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }.map(\.id)
    }

    /// The files the index lists in the sheet's order, the projects in `order`, each with the
    /// files of the saved explanation first and then the newest. A file in the folders of two
    /// projects shows once, under the one that comes first, and a file of a project not in
    /// `order` not at all. Off the main actor, since the projects may hold thousands of files.
    @concurrent
    nonisolated static func arrange(_ listed: [FolderIndex.ListedFile], order: [UUID], inExplanation: Set<String>) async -> Listing {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var held: [String: FolderIndex.ListedFile] = [:]
        for file in listed {
            guard let place = rank[file.project] else { continue }
            let key = file.url.path.lowercased()
            if let before = held[key], rank[before.project, default: .max] <= place { continue }
            held[key] = file
        }
        var listing = Listing()
        var rows: [UUID: [Row]] = [:]
        for (key, file) in held {
            let row = Row(project: file.project, url: file.url, modified: file.modified, reading: file.reading, isInExplanation: inExplanation.contains(file.url.path))
            rows[file.project, default: []].append(row)
            listing.byPath[key] = row
        }
        listing.projects = order.compactMap { project in
            rows[project].map { found in
                Listing.Files(project: project, rows: found.sorted { first, second in
                    if first.isInExplanation != second.isInExplanation { return first.isInExplanation }
                    if first.modified != second.modified { return (first.modified ?? .distantPast) > (second.modified ?? .distantPast) }
                    return first.url.path < second.url.path
                })
            }
        }
        return listing
    }

    /// The sections for the search as it is: the email's project first, then the other
    /// projects by name, each with its files that match, those of the saved explanation first
    /// and then the newest, then the chosen files the index lacks. A file in the folders of two
    /// projects shows once, under the email's project when it is one of them, else under the
    /// first of them by name. A project without files has no section, and while a search runs
    /// neither has one without a match.
    var sections: [Section] {
        Self.sections(
            listing, names: Dictionary(runtime.projectList.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            emailProject: email.project, ticks: ticks, query: query,
            indexing: Set(runtime.projectList.map(\.id).filter { runtime.indexReport($0)?.isIndexing == true }), limit: shownPerSection)
    }

    /// The sections of `listing` for a search, with the first `limit` files that match of each
    /// project and every chosen one. A project `names` lacks, such as one forgotten since the
    /// files were read, has none.
    nonisolated static func sections(
        _ listing: Listing, names: [UUID: String], emailProject: UUID?, ticks: [MailStore.ChosenFile], query: String, indexing: Set<UUID>,
        limit: Int = sectionLimit
    ) -> [Section] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !text.isEmpty
        func matches(_ url: URL) -> Bool {
            !searching || url.lastPathComponent.localizedStandardContains(text)
        }
        var sections: [Section] = []
        for project in listing.projects {
            guard let name = names[project.project] else { continue }
            let rows = searching ? project.rows.filter { matches($0.url) } : project.rows
            guard !rows.isEmpty else { continue }
            var shown = Array(rows.prefix(limit))
            if rows.count > limit {
                // The chosen files past the limit show too.
                let ids = Set(shown.map(\.id))
                shown += ticks.compactMap { listing.byPath[$0.path.lowercased()] }
                    .filter { $0.project == project.project && !ids.contains($0.id) && matches($0.url) }
            }
            sections.append(Section(
                kind: .project(project.project), title: project.project == emailProject ? ProjectsWindowText.emailsProject(name) : name,
                rows: shown, total: rows.count, isIndexing: indexing.contains(project.project)))
        }
        // By their path alone, never looked up on the disk.
        let missing = ticks.filter { listing.byPath[$0.path.lowercased()] == nil }
            .map { Row(project: $0.project, url: URL(filePath: $0.path, directoryHint: .notDirectory)) }
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
            stopWaiting(for: row.url.path)
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
        waiting = nil
        notice = nil
    }

    /// Whether the file at `path` can be ticked: it is ticked already, or fewer than the most
    /// files are.
    private func canTick(_ path: String) -> Bool {
        ticks.count < ExplainPrompt.chosenFileLimit || ticks.contains { $0.path.lowercased() == path.lowercased() }
    }

    /// A dropped file the user unticked before the index listed it: the sheet waits for it no
    /// longer, and the line that it is chosen once read goes.
    private func stopWaiting(for path: String) {
        guard waiting == path.lowercased() else { return }
        waiting = nil
        if case .reading = notice {
            notice = nil
        }
    }

    // MARK: Dropped files

    /// Files dragged onto the list from Finder, each placed by its path alone, never opened
    /// or looked up: a file the index lists is ticked and shown, in any project and also past
    /// the files a section shows, a folder says that it is none, one inside a project folder
    /// that the index does not list says so, and one outside every folder offers to add its
    /// folder to a project, unless the choice is full.
    func drop(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let key = url.path.lowercased()
            if let row = listing.byPath[key] {
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
            } else if url.hasDirectoryPath, !Self.isDocumentPackage(url) {
                notice = .folder(url.lastPathComponent)
            } else if roots.values.contains(where: { roots in
                if case .outside = ProjectsEmailFiles.place(of: url, in: roots) { return false }
                return true
            }) {
                notice = .notRead(url.lastPathComponent)
            } else if !canTick(url.path) {
                // No folder is offered for a file that could not be chosen.
                notice = .limit
            } else {
                notice = .outside(url)
            }
        }
    }

    /// Whether a dropped folder is one Finder shows as a file, by its extension alone: a
    /// Keynote, Numbers or Pages document, which the index lists by name, see
    /// FolderWalk.documentPackages, or another package. Finder ends the address of a folder
    /// with a slash, so nothing looks at the disk.
    private nonisolated static func isDocumentPackage(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return false }
        return FolderWalk.documentPackages.contains(fileExtension) || UTType(filenameExtension: fileExtension, conformingTo: .package).map { !$0.isDynamic } == true
    }

    /// Adds the folder the user picked in the open panel to a project, for all its mail, for
    /// a dropped file or with nil for Add a Folder: a folder that does not hold the dropped file
    /// is not added, nor one for a file that could not be ticked, and a refused one says why.
    /// The dropped file is ticked at once, and the sheet says so once the index lists it.
    func addFolder(_ folder: URL, to project: UUID, for dropped: URL?) async {
        if let dropped {
            guard case .inFolder = ProjectsEmailFiles.place(of: dropped, in: ProjectsEmailFiles.Roots(folders: [folder])) else {
                notice = .notInFolder(dropped.lastPathComponent)
                return
            }
            guard canTick(dropped.path) else {
                notice = .limit
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
    /// project of its row, and the sheet says that it is chosen. A file the user unticked
    /// meanwhile stays unticked.
    private func takeWaitingFile() {
        guard let waiting, let row = listing.byPath[waiting] else { return }
        self.waiting = nil
        guard let index = ticks.firstIndex(where: { $0.path.lowercased() == waiting }) else { return }
        ticks[index] = MailStore.ChosenFile(project: row.project, path: row.url.path)
        notice = .chosen(row.url.lastPathComponent)
        scrollTarget = row.id
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

    /// The line under Explain or Explain Again for the email's choice as saved now, against
    /// the explanation the store holds now, also for an email whose view did not show in
    /// this window, see ProjectsEmailModel.choiceNote(chosen:explanation:).
    func choiceNote() async -> ProjectsEmailModel.ChoiceNote? {
        let explanation = await runtime.explanation(for: email.messageID)
        return ProjectsEmailModel.choiceNote(chosen: emailModel.chosenFiles, explanation: explanation)
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
    /// The sheet's height, for the footer: all of it under the list, or in a sheet too low
    /// for that only the drag line and Add a Folder, with the two lines about the choice at
    /// the end of the list, so the list keeps its rows.
    @State private var height: CGFloat = 560

    /// The lowest sheet whose whole footer stays under the list. In Spanish at 520 points
    /// wide, the header, the footer and the buttons in two rows take about 310 points, so a
    /// lower sheet would leave the list less than its 120 points, and some room is left for
    /// larger text.
    static let compactHeight: CGFloat = 470

    /// A folder to add to a project, with the dropped file it is for, if any.
    struct Panel: Equatable {
        var project: Project
        var dropped: URL?
    }

    /// Reads the files again when an index starts or ends reading a project's folders, such
    /// as after a folder was added, or the projects' folders or names change. While an index
    /// reads, the sheet reads them again every `ProjectsFileChoice.followInterval`, not at
    /// each file the index reads.
    private struct Reload: Hashable {
        var indexing: Set<UUID>
        var folders: [UUID: [Data]]
        var names: [UUID: String]
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

    /// The email as the window's list shows it now, so the sheet says Explain Again once a
    /// first explanation ended while it showed, as the email's header does.
    private var current: MailStore.Listed {
        model.listed(email.messageID) ?? email
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 10)
            Divider()
            list
                .frame(minHeight: 120)
            Divider()
            Group {
                if isCompact {
                    dropControls
                } else {
                    footer
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isCompact ? 8 : 10)
            Divider()
            buttons
                .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 380, idealHeight: 560)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .task(id: reload) {
            await choice.load()
            // While an index reads, its files show as it reads them.
            while !reload.indexing.isEmpty {
                try? await Task.sleep(for: ProjectsFileChoice.followInterval)
                guard !Task.isCancelled else { return }
                await choice.load()
            }
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
        var reload = Reload(indexing: [], folders: [:], names: [:])
        for project in runtime.projectList {
            if runtime.indexReport(project.id)?.isIndexing == true {
                reload.indexing.insert(project.id)
            }
            reload.folders[project.id] = project.folders
            reload.names[project.id] = project.name
        }
        return reload
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
                // In a sheet too low for the whole footer, the two lines about the choice
                // come after the files, and the drag line and Add a Folder stay under the list.
                if isCompact {
                    choiceLines
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
            choiceLines
            dropControls
        }
    }

    /// What Orra does with the files, and which button uses the choice.
    private var choiceLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Orra puts the passages of these files that best fit this email first, or a file's beginning, then adds what its own search finds. Of a file without text, the model gets only its name.")
            Group {
                if current.isExplained {
                    Text("This choice is for this email only. Explain Again uses it.")
                } else {
                    Text("This choice is for this email only. Explain uses it.")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The drag line and Add a Folder, the button under the line where they do not fit side
    /// by side.
    private var dropControls: some View {
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
                addFolder(for: file)
            }
        }
        .font(.callout)
    }

    /// Add a Folder to the email's project, or for an email without one a menu of the
    /// projects, which opens the open panel, in the folder of the dropped file when there is
    /// one. While Projects has no project, the line that says to make one.
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
        } else {
            Text("Make a project with New Project… and add the folder there.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                if let note = await choice.choiceNote() {
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
            if current.isExplained {
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
            && ProjectsWindowText.noText(current) == nil && runtime.phase == .on
    }
}
