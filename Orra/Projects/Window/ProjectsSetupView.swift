import SwiftUI
import UniformTypeIdentifiers

/// Sets up a new project or changes one: its name and description, its folders by the open
/// panel or by drag, its people with their roles, its domains and a linked Mail mailbox.
///
/// A suggestion of Suggested Projects opens it as a new project, prefilled with the
/// suggestion's name, description, people, domains and mailbox, which the user can change,
/// save or dismiss.
///
/// The names of Mail's mailboxes are read only when the user asks for them, and only while
/// Mail runs. Folders are kept as plain bookmarks, see Project.bookmark(of:). Projects never
/// writes, moves or deletes anything in them.
struct ProjectsSetupView: View {
    /// A project as the sheet edits it.
    struct Draft: Identifiable {
        struct Person: Identifiable {
            let id = UUID()
            var name = ""
            var address = ""
            var role = ""
        }

        struct Folder: Identifiable {
            let id = UUID()
            var bookmark: Data
            /// Where the folder is now, nil until resolved or when it is gone.
            var url: URL?
            /// Whether its bookmark was resolved, so a folder not resolved yet is not shown
            /// as gone.
            var isResolved = false
        }

        let id: UUID
        let isNew: Bool
        var name = ""
        var description = ""
        var folders: [Folder] = []
        var people: [Person] = []
        /// The domains as the user typed them, separated by commas or spaces.
        var domains = ""
        /// The linked mailbox, in the form of `ProjectsRuntime.mailboxName(_:)`.
        var mailbox: String?
        /// Kept as they are, since the sheet does not edit them.
        var rules: [Project.Rule] = []
        var otherMailboxes: [String] = []
        /// The suggestion a new project was prefilled from, nil for any other.
        var suggestion: ProjectSuggestionService.Suggestion?

        /// A new project.
        init() {
            id = UUID()
            isNew = true
        }

        /// A new project prefilled from a suggestion of Suggested Projects.
        init(suggestion: ProjectSuggestionService.Suggestion) {
            self.init()
            self.suggestion = suggestion
            name = suggestion.name
            description = suggestion.description
            people = suggestion.group.people.map { Person(name: $0.name, address: $0.address) }
            domains = suggestion.group.domains.joined(separator: ", ")
            mailbox = suggestion.group.mailbox
        }

        /// A project to change.
        init(_ project: Project) {
            id = project.id
            isNew = false
            name = project.name
            description = project.description
            folders = project.folders.map { Folder(bookmark: $0) }
            people = project.people.map { Person(name: $0.name, address: $0.address, role: $0.role) }
            domains = project.domains.joined(separator: ", ")
            mailbox = project.mailboxes.first
            otherMailboxes = Array(project.mailboxes.dropFirst())
            rules = project.rules
        }

        /// The person with this ID, nil once removed.
        func person(_ id: UUID) -> Person? {
            people.first { $0.id == id }
        }

        /// Changes the person with the same ID. A person removed meanwhile stays removed.
        mutating func update(_ person: Person) {
            guard let index = people.firstIndex(where: { $0.id == person.id }) else { return }
            people[index] = person
        }

        /// The people with an address, each in the form of ProjectsAddress, or nil when one
        /// is not an address.
        var validPeople: [Project.Person]? {
            var people: [Project.Person] = []
            for person in self.people {
                let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let address = person.address.trimmingCharacters(in: .whitespacesAndNewlines)
                let role = person.role.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty, address.isEmpty, role.isEmpty { continue }
                guard let normalized = ProjectsAddress.normalized(address) else { return nil }
                people.append(Project.Person(name: name, address: normalized, role: role))
            }
            return people
        }

        /// Why a domain cannot be saved.
        nonisolated enum DomainProblem: Error, Equatable {
            case notADomain
            /// A mail provider that many unrelated people share, or a domain under one, as
            /// ProjectSuggestions.isSharedProvider(_:) finds it. Every address there would
            /// count as one of the project's people.
            case sharedProvider(String)
        }

        /// The domains in lowercase without an @ in front, or why one cannot be saved.
        var checkedDomains: Result<[String], DomainProblem> {
            var domains: [String] = []
            let separators = CharacterSet(charactersIn: ",;，、").union(.whitespacesAndNewlines)
            for part in self.domains.components(separatedBy: separators) where !part.isEmpty {
                let domain = part.hasPrefix("@") ? String(part.dropFirst()) : part
                guard domain.contains("."), let address = ProjectsAddress.normalized("x@" + domain),
                      let normalized = address.split(separator: "@").last.map(String.init) else { return .failure(.notADomain) }
                guard !ProjectSuggestions.isSharedProvider(normalized) else { return .failure(.sharedProvider(normalized)) }
                if !domains.contains(normalized) {
                    domains.append(normalized)
                }
            }
            return .success(domains)
        }

        /// The domains to save, or nil while one cannot be saved.
        var validDomains: [String]? {
            try? checkedDomains.get()
        }

        /// The project to save, or nil while the name is empty or a person or a domain is
        /// not valid.
        var project: Project? {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let people = validPeople, let domains = validDomains else { return nil }
            return Project(
                id: id,
                name: name,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                folders: folders.map(\.bookmark),
                people: people,
                domains: domains,
                rules: rules,
                mailboxes: (mailbox.map { [$0] } ?? []) + otherMailboxes.filter { $0 != mailbox }
            )
        }
    }

    /// A domain to show how one is written.
    static let exampleDomain = "harbor.example"
    /// A mail provider to show which domains the sheet refuses, one of
    /// SortingService.sharedMailDomains.
    static let sharedProviderExample = "gmail.com"

    let runtime: ProjectsRuntime
    @State var draft: Draft
    /// Called with the project's ID once it is saved, or nil when the user cancels.
    let done: (UUID?) -> Void
    /// Dismisses the suggestion the project was prefilled from. The sheet shows Dismiss
    /// Suggestion only with it.
    var dismissSuggestion: (() -> Void)? = nil
    @State private var isChoosingFolders = false
    /// Why the last folder added was refused.
    @State private var folderProblem: String?
    @State private var mailboxes: [String] = []
    @State private var mailboxProblem: String?
    @State private var isReadingMailboxes = false
    @State private var isSaving = false
    @State private var saveFailed = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if draft.isNew {
                    Text("New Project")
                } else {
                    Text("Edit Project")
                }
            }
            .font(.headline)
            .padding(.top, 14)
            Form {
                if let suggestion = draft.suggestion {
                    Section {
                        Label {
                            Text("Suggested from your mail in Needs a Project, where it would take \(suggestion.group.takes.count) emails. Check the name, the people and the domains, and add the project's folders.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(2...5)
                    Text("What the project is, who the other side is and which language they write in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                folderSection
                peopleSection
                Section {
                    TextField("Domains", text: $draft.domains, prompt: Text(verbatim: "\(Self.exampleDomain), port.example"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    if case .failure(let problem) = draft.checkedDomains {
                        Text(verbatim: Self.problem(with: problem))
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Domains")
                } footer: {
                    Text("Addresses at these domains count as the project's people. Their mail goes to the project, and a reply to them counts as staying inside the project. For a mail provider many people share, such as \(Self.sharedProviderExample), add each person under People instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                mailboxSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let dismissSuggestion {
                    Button("Dismiss Suggestion") {
                        dismissSuggestion()
                        done(nil)
                    }
                    .help(ProjectsSuggestedSection.dismissalNote)
                }
                if saveFailed {
                    Text(verbatim: ProjectsWindowText.notice(.projectNotSaved))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    done(nil)
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.project == nil || isSaving || runtime.phase != .on)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 640)
        .fileImporter(isPresented: $isChoosingFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                add(urls)
            }
        }
        .task {
            for folder in draft.folders where !folder.isResolved {
                let url = await Project.resolve([folder.bookmark]).first
                guard let index = draft.folders.firstIndex(where: { $0.id == folder.id }) else { continue }
                draft.folders[index].url = url
                draft.folders[index].isResolved = true
            }
        }
    }

    // MARK: Sections

    private var folderSection: some View {
        Section {
            ForEach(draft.folders) { folder in
                HStack {
                    Label {
                        if let url = folder.url {
                            Text(verbatim: url.path)
                                .lineLimit(1)
                                .truncationMode(.head)
                        } else if folder.isResolved {
                            Text("Folder not found")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                    Spacer()
                    removeButton {
                        draft.folders.removeAll { $0.id == folder.id }
                    }
                }
            }
            if let folderProblem {
                Text(verbatim: folderProblem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Add Folder…") {
                isChoosingFolders = true
            }
        } header: {
            Text("Folders")
        } footer: {
            Text("Or drag folders here. Projects reads the files in them and never changes them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            add(folders)
            return !folders.isEmpty
        }
    }

    /// Each row binds to its person by ID, not by position. A field of a removed row can still
    /// read and write its text after the removal, and by position that would read past the end
    /// of the list or change the person who took its place. The footer says what the people
    /// do, as the one of Domains does: a person among an email's other side names the project
    /// in sorting, and the draft check counts a reply to the project's people as inside it.
    private var peopleSection: some View {
        Section {
            ForEach(draft.people) { person in
                let row = Binding(get: { draft.person(person.id) ?? person }, set: { draft.update($0) })
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Name", text: row.name, prompt: Text("Name"))
                            TextField("Email Address", text: row.address, prompt: Text("Email Address"))
                        }
                        .textFieldStyle(.roundedBorder)
                        TextField("Role", text: row.role, prompt: Text("Role, such as their architect"))
                            .textFieldStyle(.roundedBorder)
                        if let problem = Self.problem(with: person) {
                            Text(verbatim: problem)
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    removeButton {
                        draft.people.removeAll { $0.id == person.id }
                    }
                }
                .labelsHidden()
            }
            Button("Add Person") {
                draft.people.append(Draft.Person())
            }
        } header: {
            Text("People")
        } footer: {
            Text("Add the people you exchange mail with on this project. Their mail goes to the project, and a reply to them counts as staying inside the project.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mailboxSection: some View {
        Section {
            Picker("Linked Mailbox", selection: $draft.mailbox) {
                Text("No Linked Mailbox").tag(String?.none)
                ForEach(Self.choices(mailboxes, current: draft.mailbox), id: \.self) { name in
                    Text(verbatim: ProjectsWindowText.mailbox(name)).tag(String?.some(name))
                }
            }
            .labelsHidden()
            HStack {
                Button("Read Mailbox Names from Mail") {
                    readMailboxes()
                }
                .disabled(isReadingMailboxes)
                if isReadingMailboxes {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let mailboxProblem {
                Text(verbatim: mailboxProblem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Linked Mailbox")
        } footer: {
            Text("Mail in this mailbox goes to the project. Projects reads it along with the mailboxes you chose in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Remove"))
        .help(Text("Remove"))
    }

    // MARK: Actions

    /// Adds folders the index can read. A folder it refuses, such as the home folder, is
    /// not added, and the line under the folders says why. The sheet that chooses files for
    /// an email checks a folder the same way, see ProjectsRuntime.folderBookmark(_:).
    private func add(_ urls: [URL]) {
        folderProblem = nil
        Task {
            for url in urls {
                let bookmark: Data
                switch await ProjectsRuntime.folderBookmark(url) {
                case .failure(let refusal):
                    folderProblem = ProjectsWindowText.refusal(refusal)
                    continue
                case .success(let made):
                    bookmark = made
                }
                guard !draft.folders.contains(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) else { continue }
                draft.folders.append(Draft.Folder(bookmark: bookmark, url: url, isResolved: true))
            }
        }
    }

    private func readMailboxes() {
        isReadingMailboxes = true
        mailboxProblem = nil
        Task {
            defer { isReadingMailboxes = false }
            do {
                mailboxes = try await runtime.mailboxes().compactMap(ProjectsRuntime.mailboxName)
            } catch MailBridgeError.mailNotRunning {
                mailboxProblem = ProjectsWindowText.selection(.mailNotRunning)
            } catch MailBridgeError.denied, MailBridgeError.notAsked {
                mailboxProblem = ProjectsWindowText.selection(.notAllowed)
            } catch {
                mailboxProblem = ProjectsWindowText.selection(.failed(.unexpectedReply))
            }
        }
    }

    private func save() {
        guard let project = draft.project else { return }
        isSaving = true
        saveFailed = false
        Task {
            defer { isSaving = false }
            do {
                if draft.isNew {
                    try await runtime.add(project)
                } else {
                    try await runtime.update(project)
                }
                done(project.id)
            } catch {
                saveFailed = true
            }
        }
    }

    /// Why a person cannot be saved: an address that is not one, or a name or a role
    /// without an address. Nil for a valid person or an empty row.
    static func problem(with person: Draft.Person) -> String? {
        let address = person.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty {
            let named = !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !person.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return named ? String(localized: "Add an email address.") : nil
        }
        return ProjectsAddress.normalized(address) == nil ? String(localized: "This is not an email address.") : nil
    }

    /// Why the domains cannot be saved, in the words of the sheet.
    static func problem(with domains: Draft.DomainProblem) -> String {
        switch domains {
        case .notADomain: String(localized: "Write each domain like \(exampleDomain).")
        case .sharedProvider(let domain): String(localized: "Many unrelated people have addresses at \(domain). Add each person under People instead.")
        }
    }

    /// The mailboxes the picker offers: those read from Mail, and the linked one even while
    /// Mail's are not read.
    static func choices(_ mailboxes: [String], current: String?) -> [String] {
        guard let current, !mailboxes.contains(current) else { return mailboxes }
        return [current] + mailboxes
    }
}
