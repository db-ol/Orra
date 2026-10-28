import SwiftUI

/// The project files of an explanation, for Project Files for This Explanation in the email
/// view: each project file whose excerpts the saved explanation gave the model, once, with
/// whether a point cites it, why it was in the prompt, the project whose folders hold it,
/// the warnings found at it and its saved excerpts, and where it is in the folders of its
/// project now. It reads no file. The files come from the saved explanation, and the
/// folders from ProjectsRuntime.folderRoots(of:).
nonisolated enum ProjectsEmailFiles {
    /// An excerpt of a file as the explanation saved it, by its source id.
    nonisolated struct SavedExcerpt: Sendable, Equatable, Identifiable {
        var id: String
        var chunk: TextChunker.Chunk
        /// Whether the hygiene took lines out of it before the model read it.
        var takenOut: Bool
    }

    /// A file whose excerpts the explanation gave the model.
    nonisolated struct File: Sendable, Equatable, Identifiable {
        var url: URL
        /// Its excerpts in the order of their source ids.
        var excerpts: [SavedExcerpt]
        /// Whether a point under What it says names one of its excerpts as its source. The
        /// places of warnings are findings of the checks, not citations.
        var isCited: Bool
        /// Why it was in the prompt, as its first excerpt says. Nil in an explanation saved
        /// before Orra 0.6.1, and for a reason this Orra does not know.
        var reason: ExplainPrompt.FileOrigin.Reason?
        /// The project whose folders hold it: its origin's, or else the explanation's.
        var project: UUID?
        /// What the checks found at its excerpts, each kind once, in the order of
        /// `ProjectsWarning.allCases`.
        var warnings: [ProjectsWarning]
        /// Why a file the user chose gave the explanation nothing, see `chosenWithoutExcerpts(in:)`.
        var missing: Explanation.ChosenFile.Missing? = nil

        var id: URL { url }

        /// Whether the prompt gave the model the file's name only: a chosen file without
        /// text, whose saved chunk has none.
        var isNameOnly: Bool {
            !excerpts.isEmpty && excerpts.allSatisfy { $0.chunk.text.isEmpty }
        }

        /// The number on the chip of each of its excerpts, in their order: the excerpt's
        /// place among the excerpts of its page, slide or sheet, or among those of a file
        /// without them, when there are several, so no two chips of the file read the same.
        /// Nil for an excerpt alone on its page, slide or sheet, or the one excerpt of a file
        /// without them. The places are those the chips name, see
        /// ProjectsWindowText.place(of:), so the excerpts of two sheets never share numbers.
        var chipNumbers: [Int?] {
            let places = excerpts.map { ProjectsWindowText.place(of: $0.chunk) }
            var counts: [ProjectsWindowText.Place?: Int] = [:]
            for place in places {
                counts[place, default: 0] += 1
            }
            var numbers: [ProjectsWindowText.Place?: Int] = [:]
            return places.map { place in
                guard counts[place, default: 0] > 1 else { return nil }
                numbers[place, default: 0] += 1
                return numbers[place]
            }
        }
    }

    /// The files of the explanation's file sources, each once, in the order of their first
    /// source id, which is the order of the prompt: F1 first, the ids by their number and
    /// not as text, so F10 follows F9, and ids of another letter after them.
    static func files(in explanation: Explanation) -> [File] {
        let excerpts = explanation.sources.compactMap { id, source -> (excerpt: SavedExcerpt, origin: ExplainPrompt.FileOrigin?)? in
            guard case .file(let chunk, let origin) = source else { return nil }
            let takenOut = !(explanation.removed[.file(id)] ?? []).isEmpty
            return (SavedExcerpt(id: id, chunk: chunk, takenOut: takenOut), origin)
        }
        .sorted { order($0.excerpt.id) < order($1.excerpt.id) }
        let cited = Set(explanation.points.flatMap(\.sources))
        var files: [File] = []
        var places: [URL: Int] = [:]
        for (excerpt, origin) in excerpts {
            if let index = places[excerpt.chunk.file] {
                files[index].excerpts.append(excerpt)
                files[index].isCited = files[index].isCited || cited.contains(excerpt.id)
            } else {
                places[excerpt.chunk.file] = files.count
                files.append(File(
                    url: excerpt.chunk.file, excerpts: [excerpt], isCited: cited.contains(excerpt.id),
                    reason: origin?.reason, project: origin?.project ?? explanation.project, warnings: []))
            }
        }
        for index in files.indices {
            let ids = Set(files[index].excerpts.map(\.id))
            let kinds = Set(explanation.warnings.compactMap { finding -> ProjectsWarning? in
                guard case .file(let id) = finding.place, ids.contains(id) else { return nil }
                return finding.warning
            })
            files[index].warnings = ProjectsWarning.allCases.filter(kinds.contains)
        }
        return files
    }

    /// The files the user chose for the email that gave its explanation nothing, which the
    /// index did not hold or the budget left out, in the order of the choice, with no excerpt.
    /// By their path alone, never looked up on the disk, since such a file may have left the
    /// project folders.
    static func chosenWithoutExcerpts(in explanation: Explanation) -> [File] {
        (explanation.chosenFiles ?? []).filter { $0.sources.isEmpty }.map { chosen in
            File(
                url: URL(filePath: chosen.path, directoryHint: .notDirectory), excerpts: [], isCited: false, reason: .chosen, project: chosen.project,
                warnings: [], missing: chosen.missing ?? .notInIndex)
        }
    }

    /// The order of source ids: F first, then by letter, then by number.
    private static func order(_ id: String) -> (Int, String, Int, String) {
        let letters = String(id.prefix { $0.isLetter })
        let number = Int(id.dropFirst(letters.count)) ?? .max
        return (letters == "F" ? 0 : 1, letters, number, id)
    }

    /// A project's folders as they are now, see ProjectsRuntime.folderRoots(of:).
    nonisolated struct Roots: Sendable, Equatable {
        /// The real paths of the folders that are there, in the project's order, since the
        /// index keeps every file at its real path, see FolderWalk.
        var folders: [URL] = []
        /// Where the folders whose bookmarks find nothing now were, such as a folder on a
        /// disk that is not connected: where each bookmark last found its folder, and the
        /// path it keeps from when the user added the folder.
        var unavailable: [URL] = []
    }

    /// Where a file is, by the folders of its project now.
    nonisolated enum Place: Sendable, Equatable {
        /// In one of the project's folders: that folder's name and the folders inside it down
        /// to the file. When the folders nest, the deepest one that holds the file counts.
        case inFolder(name: String, path: [String])
        /// In a folder of the project that is not available now, with the same parts.
        case unavailable(name: String, path: [String])
        /// In none of the project's folders, such as after its folder left the project: the
        /// folder the file is in.
        case outside(URL)
    }

    /// Where `file` is in `roots`: in the deepest folder that holds it, available or not, an
    /// available one first when both are as deep. Names are compared without case, as
    /// FolderWalk compares places, and a folder holds only what lies inside it, so /A/Lobby
    /// does not hold /A/Lobby old/plan.pdf.
    static func place(of file: URL, in roots: Roots) -> Place {
        let available = deepest(holding: file, in: roots.folders)
        let unavailable = deepest(holding: file, in: roots.unavailable)
        if let found = unavailable, found.path.count < available?.path.count ?? .max {
            return .unavailable(name: found.folder.lastPathComponent, path: found.path)
        }
        if let found = available {
            return .inFolder(name: found.folder.lastPathComponent, path: found.path)
        }
        return .outside(file.deletingLastPathComponent())
    }

    /// The deepest of `folders` that holds `file`, with the folders between them. The paths
    /// are compared as they are, both real paths, never standardized, since standardizing
    /// takes /private off the path of a folder that exists, such as /private/var, and not
    /// off that of a file that no longer does.
    private static func deepest(holding file: URL, in folders: [URL]) -> (folder: URL, path: [String])? {
        let parts = file.pathComponents
        var found: (folder: URL, path: [String])?
        var depth = 0
        for folder in folders {
            let root = folder.pathComponents
            guard root.count > depth, root.count < parts.count,
                  zip(root, parts).allSatisfy({ $0.lowercased() == $1.lowercased() }) else { continue }
            found = (folder, Array(parts[root.count..<(parts.count - 1)]))
            depth = root.count
        }
        return found
    }
}

// MARK: The section

extension ProjectsEmailArea {
    /// Project Files for This Explanation, folded after What it says. Open, it lists each
    /// project file whose excerpts the explanation gave the model, see ProjectsEmailFiles,
    /// or says why there is none, and each file the user chose that gave it nothing, then
    /// Choose Files for This Email… with Return to Automatic Selection while the email has a
    /// choice, Edit Project…, or Assign to Project for an email in no project, what the next
    /// explanation uses of the files the user chose, and when a project's folders can change,
    /// that a change counts from the next Explain Again. It starts folded for each email, and
    /// stays as the user leaves it while the window is open, see
    /// ProjectsEmailModel.showsProjectFiles.
    ///
    /// It shows the explanation as it was saved and the folders as they are now. The folders
    /// resolve only while it is open, and again when they change, such as after Edit
    /// Project…. Names and folders show as plain text, and nothing opens outside Orra.
    struct FilesSection: View {
        let model: ProjectsWindowModel
        let emailModel: ProjectsEmailModel
        let email: MailStore.Listed
        let explanation: Explanation

        /// Reads the folders again when the projects of the files or their folders change,
        /// and for another email, since the view stays as it is when the window shows another
        /// email whose list is open too.
        struct Reload: Hashable {
            var messageID: String
            /// The projects of the files, sorted.
            var projects: [UUID]
            /// The bookmarks of each of those projects' folders.
            var folders: [[Data]]

            init(messageID: String, files: [ProjectsEmailFiles.File], projectList: [Project]) {
                self.messageID = messageID
                projects = Array(Set(files.compactMap(\.project))).sorted { $0.uuidString < $1.uuidString }
                folders = projects.map { id in projectList.first { $0.id == id }?.folders ?? [] }
            }
        }

        var body: some View {
            let rows = self.rows()
            DisclosureGroup(isExpanded: Binding(get: { emailModel.showsProjectFiles }, set: { emailModel.showsProjectFiles = $0 })) {
                content(rows)
            } label: {
                Text(verbatim: ProjectsWindowText.projectFiles(rows.read.count))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            .disclosureGroupStyle(RowDisclosureStyle())
        }

        private var runtime: ProjectsRuntime {
            model.runtime
        }

        /// The email's project, while the list holds it.
        private var project: Project? {
            email.project.flatMap { id in runtime.projectList.first { $0.id == id } }
        }

        private func content(_ rows: (read: [FileRow], missing: [FileRow])) -> some View {
            let reload = Reload(messageID: emailModel.messageID, files: (rows.read + rows.missing).map(\.file), projectList: runtime.projectList)
            return VStack(alignment: .leading, spacing: 12) {
                if rows.read.isEmpty {
                    Text(verbatim: ProjectsWindowText.noProjectFiles(inProject: email.project != nil))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if project?.folders.isEmpty == true {
                        Text("No folders yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("When it explained this email, Projects gave the model excerpts of these files. Cited in explanation means a point under What it says names one of them as its source.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(rows.read, id: \.file.id) { row in
                        row
                    }
                }
                // The files the user chose that gave the model nothing, after those it read.
                ForEach(rows.missing, id: \.file.id) { row in
                    row
                }
                controls
                if let note = emailModel.choiceNote {
                    Text(verbatim: ProjectsWindowText.choiceNote(note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let project {
                    Text("Folder changes count from the next Explain Again, once indexing finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if runtime.indexReport(project.id)?.isIndexing == true {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Indexing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .task(id: reload) {
                await emailModel.loadFolderRoots(for: reload.projects)
            }
        }

        /// Choose Files for This Email… and, while the email has a choice, Return to Automatic
        /// Selection, then Edit Project… for the email's project, or Assign to Project for an
        /// email in no project. One under another in a column too narrow for a row.
        @ViewBuilder
        private var controls: some View {
            if let project {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        choiceButtons
                        editButton(project)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            choiceButtons
                        }
                        editButton(project)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        choiceButtons
                        editButton(project)
                    }
                }
            } else if email.project == nil {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            choiceButtons
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            choiceButtons
                        }
                    }
                    // Its whole name where it fits, and cut in a column too narrow for it, as in
                    // Japanese at the window's smallest size.
                    ViewThatFits(in: .horizontal) {
                        assignMenu
                            .fixedSize()
                        assignMenu
                    }
                }
            } else {
                choiceButtons
            }
        }

        /// Choose Files for This Email…, which opens the sheet, and Return to Automatic
        /// Selection while the email has a choice, which removes it at once, since nothing
        /// changes before Explain Again and a choice is easy to make again.
        /// Their titles wrap to two lines in a column too narrow for them.
        @ViewBuilder
        private var choiceButtons: some View {
            Button {
                model.chooseFiles(for: email)
            } label: {
                Text("Choose Files for This Email…")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(runtime.phase != .on || ProjectsWindowText.noText(email) != nil)
            if !emailModel.chosenFiles.isEmpty {
                Button {
                    Task { await emailModel.saveChoice([]) }
                } label: {
                    Text("Return to Automatic Selection")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(runtime.phase != .on)
            }
        }

        /// Assign to Project, with the items of the project chip's menu, which ask first when
        /// the move takes away a draft the user changed.
        private var assignMenu: some View {
            Menu("Assign to Project") {
                ProjectsWindowView.MoveMenuItems(runtime: runtime, model: model, email: email)
            }
            .disabled(runtime.phase != .on)
        }

        /// Opens the project's Edit Project sheet, as Edit Project… in Settings does, see
        /// ProjectsWindowModel.edit(_:).
        private func editButton(_ project: Project) -> some View {
            Button("Edit Project…") {
                model.edit(project.id)
            }
            .disabled(runtime.phase != .on)
        }

        /// Where a file is now, nil while the folders of its project resolve.
        private func place(of file: ProjectsEmailFiles.File) -> ProjectsEmailFiles.Place? {
            guard let project = file.project, let roots = emailModel.folderRoots[project] else { return nil }
            return ProjectsEmailFiles.place(of: file.url, in: roots)
        }

        /// The rows the list shows, in its order: the files whose excerpts the explanation gave
        /// the model, then the files the user chose that gave it nothing. Each has the email
        /// view for Attach to Reply, those of the files the user chose too.
        func rows() -> (read: [FileRow], missing: [FileRow]) {
            (ProjectsEmailFiles.files(in: explanation).map(row), ProjectsEmailFiles.chosenWithoutExcerpts(in: explanation).map(row))
        }

        private func row(_ file: ProjectsEmailFiles.File) -> FileRow {
            FileRow(file: file, place: place(of: file), project: projectLine(file), emailModel: emailModel)
        }

        /// The project of a file of another project than the email's, nil for the email's own.
        private func projectLine(_ file: ProjectsEmailFiles.File) -> String? {
            guard let id = file.project, id != explanation.project else { return nil }
            return ProjectsWindowText.otherProject(runtime.projectList.first { $0.id == id }?.name)
        }
    }

    /// One file of the list: its name, the folder that holds it, whether a point cites it,
    /// why it was in the prompt, its project when that is not the email's, and the warnings
    /// found at it, as one element for VoiceOver, then a chip for each saved excerpt, and
    /// Attach to Reply while files can be ticked for the reply. As the attachments under
    /// Original Email show, see ProjectsAttachmentList.
    struct FileRow: View {
        let file: ProjectsEmailFiles.File
        /// Where the file is now, nil while the folders resolve.
        let place: ProjectsEmailFiles.Place?
        /// The line that names the project of a file of another project.
        let project: String?
        /// The email view, for Attach to Reply, nil where the row shows without it.
        var emailModel: ProjectsEmailModel? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: file.url.lastPathComponent)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(Text(verbatim: file.url.path))
                        Group {
                            if let place {
                                Text(verbatim: ProjectsWindowText.folder(place))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                if let note = ProjectsWindowText.placeNote(place) {
                                    Text(verbatim: note)
                                }
                            }
                            if file.missing == nil {
                                Text(verbatim: ProjectsWindowText.citation(file.isCited))
                            }
                            if let reason = ProjectsWindowText.fileReason(file.reason) {
                                Text(verbatim: reason)
                            }
                            if file.isNameOnly {
                                Text("Name only")
                            }
                            if let missing = file.missing {
                                Text(verbatim: ProjectsWindowText.chosenMissing(missing))
                            }
                            if let project {
                                Text(verbatim: project)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        ForEach(file.warnings, id: \.self) { warning in
                            Label {
                                Text(verbatim: ProjectsWindowText.warning(warning))
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                // A chosen file's name has no excerpt to show.
                if !file.isNameOnly {
                    ExcerptChips(file: file)
                        .padding(.leading, 26)
                }
                if let emailModel {
                    AttachToggle(url: file.url, emailModel: emailModel)
                        .padding(.leading, 26)
                }
            }
        }
    }

    /// The chips of a file's saved excerpts, in a row, or one under another in a column too
    /// narrow for the row.
    struct ExcerptChips: View {
        let file: ProjectsEmailFiles.File

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
            let numbers = file.chipNumbers
            return ForEach(Array(file.excerpts.enumerated()), id: \.element.id) { index, excerpt in
                ExcerptChip(excerpt: excerpt, number: numbers[index])
            }
        }
    }

    /// A saved excerpt's chip: its page, slide or sheet, or Saved Excerpt, which shows the
    /// excerpt in the popover of a file's source chip.
    struct ExcerptChip: View {
        let excerpt: ProjectsEmailFiles.SavedExcerpt
        /// Its number among the file's excerpts of its page, slide or sheet, or of a file
        /// without them, nil when it is the only one there, see
        /// ProjectsEmailFiles.File.chipNumbers.
        let number: Int?
        @State private var showsExcerpt = false

        var body: some View {
            Button {
                showsExcerpt = true
            } label: {
                // Cut in the middle, as the source chips are, so a number at the end stays
                // in a column too narrow for the chip.
                Text(verbatim: ProjectsWindowText.excerptChip(excerpt.chunk, number: number))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel(Text(verbatim: ProjectsWindowText.excerptChipLabel(excerpt.chunk, number: number)))
            .popover(isPresented: $showsExcerpt, arrowEdge: .bottom) {
                Excerpt(source: .file(excerpt.chunk), emailText: "", takenOut: excerpt.takenOut)
            }
        }
    }
}
