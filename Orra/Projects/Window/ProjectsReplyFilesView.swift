import SwiftUI
import UniformTypeIdentifiers

extension ProjectsEmailArea {
    /// Files This Email Asks For, after Before you reply: the intro, the line that Projects
    /// does not know the sender, and for each request the sentence that asks, as the email
    /// words it, with the files that may be it, best first, each with Attach to Reply, never
    /// ticked when it shows. A request that says no file by name says so, one whose files
    /// were not found says so with Look Again, and a sender that looks spoofed gets only the
    /// line that Orra offers no files. Names and folders show as plain text, and nothing
    /// opens outside Orra. See ProjectsReplyFiles.
    struct FilesAskedFor: View {
        let runtime: ProjectsRuntime
        let emailModel: ProjectsEmailModel

        var body: some View {
            let files = emailModel.replyFiles
            if files.hasRequests {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Files This Email Asks For")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if files.scope == .spoofed {
                        ReplyWarningLine(text: ProjectsWindowText.scope(.spoofed) ?? "")
                    } else {
                        Text("Orra looked for these by name and by text in the folders you added to projects. Check each file before you tick it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if files.senderIsUnknown {
                            ReplyWarningLine(text: String(localized: "Projects does not know this sender. Check who is asking before you send a file."))
                                .font(.callout)
                        }
                        if let line = ProjectsWindowText.scope(files.scope) {
                            Text(verbatim: line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(files.groups) { group in
                            request(group)
                        }
                    }
                }
                .task(id: projects(files)) {
                    await emailModel.loadFolderRoots(for: projects(files))
                }
            }
        }

        /// The projects of the files found, whose folders their folder lines need.
        private func projects(_ files: ProjectsReplyFiles) -> [UUID] {
            Array(Set(files.groups.flatMap { $0.files ?? [] }.map(\.project))).sorted { $0.uuidString < $1.uuidString }
        }

        @ViewBuilder
        private func request(_ group: ProjectsReplyFiles.Group) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(verbatim: group.request.sentence)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "text.quote")
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: ProjectsWindowText.request(group.request)))
                if !group.request.saysWhichFile {
                    note(String(localized: "The email asks for a file but does not say which one."))
                } else if let found = group.files {
                    if found.isEmpty {
                        notFound
                    }
                    ForEach(found) { file in
                        RequestedFileRow(file: file, emailModel: emailModel)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Looking for files…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 26)
                }
            }
        }

        /// No file found, with Look Again, and Indexing… while an index of a project works.
        @ViewBuilder
        private var notFound: some View {
            if emailModel.replyFiles.scope != .nowhere {
                note(String(localized: "Orra found no file for this in the folders you added to projects."))
                HStack(spacing: 10) {
                    Button("Look Again") {
                        emailModel.replyFiles.lookAgain()
                    }
                    .disabled(runtime.phase != .on || emailModel.replyFiles.isLooking)
                    if runtime.projectList.contains(where: { runtime.indexReport($0.id)?.isIndexing == true }) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Indexing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 26)
            }
        }

        private func note(_ text: String) -> some View {
            Text(verbatim: text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
        }
    }

    /// A file that a request may mean: its name, its folder, the project that holds it when
    /// that is not the email's, when it changed and whether a newer file replaced it, as one
    /// element for VoiceOver, then Attach to Reply. As B's rows of the explanation's files show
    /// a file, see FileRow.
    struct RequestedFileRow: View {
        let file: RequestedFile
        let emailModel: ProjectsEmailModel

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
                            if let roots = emailModel.folderRoots[file.project] {
                                Text(verbatim: ProjectsWindowText.folder(ProjectsEmailFiles.place(of: file.url, in: roots)))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            if file.project != emailModel.replyFiles.emailProject {
                                Text(verbatim: ProjectsWindowText.otherProject(emailModel.replyFiles.projectName(file.project)))
                            }
                            Text("Changed \(file.modified.formatted(date: .abbreviated, time: .omitted))")
                            if file.isOlderVersion {
                                Text("Older version")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                AttachToggle(url: file.url, emailModel: emailModel)
                    .padding(.leading, 26)
            }
        }
    }

    /// Attach to Reply, the checkbox of a file in Files This Email Asks For and in Project
    /// Files for This Explanation, with the reason when the file cannot go. Ticking it ticks
    /// the file everywhere it shows. It shows only while files can be ticked, so never for a
    /// sender that looks spoofed, and waits while a handoff runs, which takes the files as
    /// they are ticked at its click.
    struct AttachToggle: View {
        let url: URL
        let emailModel: ProjectsEmailModel

        var body: some View {
            let files = emailModel.replyFiles
            if files.offersFiles {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: Binding(
                        get: { files.isTicked(url) },
                        set: { ticked in Task { await files.setTicked(url, ticked) } }
                    )) {
                        Text("Attach to Reply")
                    }
                    .toggleStyle(.checkbox)
                    .disabled(emailModel.isHandingOff)
                    .accessibilityLabel(Text(verbatim: ProjectsWindowText.attachLabel(url.lastPathComponent)))
                    .accessibilityHint(Text("Attaches the file when you open the reply in Mail."))
                    if let problem = files.problem(at: url) {
                        Text(verbatim: ProjectsWindowText.replyFileProblem(problem))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Attachments for the Reply, in the draft section after the answer check: the ticked
    /// files in the order ticked, each with Remove, its folder, the people a reply may reach
    /// outside its project in orange and why it cannot go when a check found it, then the
    /// footer, the total size when it is large, the cap, and Add File… with what it refused.
    /// Files dropped on it from Finder go through the same check as Add File…, and a row can
    /// be dragged out as its file, such as into the reply window, while its file passed its
    /// last check. Remove, Add File… and dropping wait while a handoff runs. A sender that
    /// looks spoofed gets only the line that Orra attaches no files.
    struct ReplyAttachments: View {
        let emailModel: ProjectsEmailModel
        @State private var isChoosing = false
        @State private var startFolder: URL?

        var body: some View {
            let files = emailModel.replyFiles
            VStack(alignment: .leading, spacing: 8) {
                Text("Attachments for the Reply")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if files.senderLooksSpoofed {
                    ReplyWarningLine(text: String(localized: "Orra attaches no files to a reply to this sender, who may not be who they claim to be."))
                        .font(.callout)
                } else {
                    if files.ticked.isEmpty {
                        Text("No files.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(files.ticked) { file in
                        TickedFileRow(file: file, emailModel: emailModel)
                    }
                    Group {
                        // Said before the click, as the files reach Mail with it. A blank draft
                        // with files goes as no draft does.
                        if !files.ticked.isEmpty, emailModel.handsOffDraft {
                            Text("Open Reply in Mail and Reply All add these files to the reply, and Mail may save it with them to your account's Drafts on the mail server before you send it. Copy copies only the draft.")
                        } else if !files.ticked.isEmpty {
                            Text("Opening the reply in Mail adds these files to it, and Mail may save it with them to your account's Drafts on the mail server before you send it.")
                        }
                        if files.areLarge {
                            Text(verbatim: ProjectsWindowText.largeTotal(ReplyFiles.total(of: files.ticked)))
                        }
                        if files.reachedCap {
                            Text(verbatim: ProjectsWindowText.attachCap)
                        }
                        ForEach(files.refusals, id: \.self) { refusal in
                            Text(verbatim: ProjectsWindowText.refusal(refusal))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Add File…") {
                        isChoosing = true
                    }
                    .disabled(emailModel.isHandingOff)
                    .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                        guard case .success(let urls) = result else { return }
                        Task { await files.add(urls) }
                    }
                    .fileDialogDefaultDirectory(startFolder)
                    .fileDialogMessage(Text("Choose files in the folders you added to a project."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dropDestination(for: URL.self) { urls, _ in
                guard files.offersFiles, !emailModel.isHandingOff, !urls.isEmpty else { return false }
                Task { await files.add(urls) }
                return true
            }
            .task(id: files.emailProject) {
                startFolder = await files.defaultFolder()
            }
            .task(id: projects(files)) {
                await emailModel.loadFolderRoots(for: projects(files))
            }
            .onChange(of: files.reachedCap) { _, reached in
                if reached {
                    AccessibilityNotification.Announcement(ProjectsWindowText.attachCap).post()
                }
            }
        }

        /// The projects of the ticked files, whose folders their folder lines need.
        private func projects(_ files: ProjectsReplyFiles) -> [UUID] {
            Array(Set(files.ticked.flatMap(\.projects))).sorted { $0.uuidString < $1.uuidString }
        }
    }

    /// A ticked file of the reply: its name, its folder and its project when that is not the
    /// email's, as one element for VoiceOver, with Remove beside them, or under them in a
    /// column too narrow for both, then the people a reply may reach outside its project and
    /// why it cannot go. When the pointer comes onto the row, the file is checked again, and
    /// the row can be dragged out as its file only while its last check found nothing, see
    /// ProjectsReplyFiles.canDrag(_:).
    struct TickedFileRow: View {
        let file: ReplyFile
        let emailModel: ProjectsEmailModel

        var body: some View {
            let files = emailModel.replyFiles
            let row = VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        info
                        Spacer()
                        removeButton
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        info
                        removeButton
                            .padding(.leading, 26)
                    }
                }
                Group {
                    let outside = files.outside(of: file)
                    if !outside.isEmpty {
                        ReplyWarningLine(text: ProjectsWindowText.outside(project: projectName, addresses: outside))
                    }
                    if let problem = files.problem(at: file.url) {
                        Text(verbatim: ProjectsWindowText.replyFileProblem(problem))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
                .padding(.leading, 26)
            }
            .onHover { inside in
                if inside {
                    Task { await files.recheck(file) }
                }
            }
            if files.canDrag(file) {
                row.draggable(file.url)
            } else {
                row
            }
        }

        /// The file's name, its folder and its project when that is not the email's.
        private var info: some View {
            let files = emailModel.replyFiles
            return Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.url.lastPathComponent)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(Text(verbatim: file.url.path))
                    Group {
                        if let project = file.projects.first, let roots = emailModel.folderRoots[project] {
                            Text(verbatim: ProjectsWindowText.folder(ProjectsEmailFiles.place(of: file.url, in: roots)))
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        if let project = file.projects.first, !file.projects.contains(where: { $0 == files.emailProject }) {
                            Text(verbatim: ProjectsWindowText.otherProject(files.projectName(project)))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }

        /// The name of the file's project for its orange line: the email's when its folders
        /// hold the file, else the first that does.
        private var projectName: String {
            let files = emailModel.replyFiles
            let project = file.projects.first { $0 == files.emailProject } ?? file.projects.first
            return project.flatMap(files.projectName) ?? String(localized: "another project")
        }

        private var removeButton: some View {
            Button("Remove") {
                emailModel.replyFiles.remove(file)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(emailModel.isHandingOff)
            .accessibilityLabel(Text(verbatim: ProjectsWindowText.removeLabel(file.url.lastPathComponent)))
        }
    }

    /// A line with the orange triangle of the window's warnings.
    struct ReplyWarningLine: View {
        let text: String

        var body: some View {
            Label {
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}
