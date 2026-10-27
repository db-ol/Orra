import SwiftUI

/// A project's page in the third column of the Projects window, while no email is selected:
/// its description, folders and the state of their index, such as "Files with text: 312",
/// "Files found by name only: 57" and "Skipped: 4" with why, the files that hide text, its
/// people, domains, rules with Remove Rule and linked mailbox, and Edit and Forget Project.
struct ProjectsProjectPage: View {
    let runtime: ProjectsRuntime
    let project: Project
    let edit: () -> Void
    let forget: () -> Void
    /// Removes a rule, after the user's yes.
    let removeRule: (Project.Rule) -> Void
    @State private var folders: [URL] = []
    @State private var skipped: [FolderIndex.SkippedFile] = []
    @State private var hiddenText: [URL] = []
    /// The rule that waits for the user's yes before it is removed.
    @State private var removing: Project.Rule?

    /// Reads the folders and the files again when the project or its index changes.
    private struct Reload: Hashable {
        var project: Project.ID
        var folders: [Data]
        var report: Int
    }

    var body: some View {
        let report = runtime.indexReport(project.id)
        Form {
            Section {
                if !project.description.isEmpty {
                    Text(verbatim: project.description)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Edit Project…", action: edit)
                    Button("Forget Project…", role: .destructive, action: forget)
                }
                .disabled(runtime.phase != .on)
            } header: {
                Text(verbatim: project.name)
                    .font(.title2.weight(.semibold))
            }
            Section("Folders") {
                if folders.isEmpty {
                    Text("No folders yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(folders, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(verbatim: folder.lastPathComponent)
                        } icon: {
                            Image(systemName: "folder")
                        }
                        Text(verbatim: folder.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let refusal = report?.refusedFolders[folder] {
                            Text(verbatim: ProjectsWindowText.refusal(refusal))
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section("Index") {
                IndexState(report: report, skipped: skipped)
            }
            if !hiddenText.isEmpty {
                Section("Files with Hidden Text") {
                    Text("Projects leaves out the text these files hide from their reader.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(hiddenText, id: \.self) { file in
                        Text(verbatim: file.lastPathComponent)
                    }
                }
            }
            Section("People") {
                if project.people.isEmpty {
                    Text("No one yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(project.people.enumerated()), id: \.offset) { _, person in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: person.name.isEmpty ? person.address : "\(person.name) <\(person.address)>")
                        if !person.role.isEmpty {
                            Text(verbatim: person.role)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !project.domains.isEmpty {
                Section("Domains") {
                    Text(verbatim: project.domains.joined(separator: ", "))
                }
            }
            if !project.rules.isEmpty {
                Section("Rules") {
                    ForEach(project.rules, id: \.self) { rule in
                        HStack {
                            Text(verbatim: ProjectsWindowText.rule(rule.sorting))
                            Spacer()
                            Button("Remove Rule…") {
                                removing = rule
                            }
                            .disabled(runtime.phase != .on)
                        }
                    }
                }
            }
            if !project.mailboxes.isEmpty {
                Section("Linked Mailbox") {
                    ForEach(project.mailboxes, id: \.self) { mailbox in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: ProjectsWindowText.mailbox(mailbox))
                            if runtime.missingMailboxes.contains(mailbox) {
                                Text("Mail has no mailbox with this name now. Choose it again in Edit Project.")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove this rule?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { rule in
            Button("Remove Rule", role: .destructive) {
                removeRule(rule)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("New mail is no longer assigned by this rule. Mail it already assigned stays in the project.")
        }
        .task(id: Reload(project: project.id, folders: project.folders, report: Self.fingerprint(report))) {
            folders = await runtime.folders(of: project)
            skipped = await runtime.skippedFiles(project.id)
            hiddenText = await runtime.filesWithHiddenText(project.id)
        }
    }

    /// The rows of the Index section: whether the index works, its counts, the limits it
    /// reached, and the files skipped with why. Each line wraps rather than being cut, also
    /// in the narrow column of the smallest window.
    struct IndexState: View {
        let report: FolderIndex.Report?
        let skipped: [FolderIndex.SkippedFile]
        @State private var showsSkipped: Bool

        init(report: FolderIndex.Report?, skipped: [FolderIndex.SkippedFile], showsSkipped: Bool = false) {
            self.report = report
            self.skipped = skipped
            _showsSkipped = State(initialValue: showsSkipped)
        }

        var body: some View {
            if let report {
                if report.isIndexing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Indexing…")
                    }
                }
                LabeledContent("Files with text") {
                    Text(report.indexed, format: .number)
                }
                LabeledContent("Files found by name only") {
                    Text(report.nameOnly, format: .number)
                }
                let skippedCount = report.skipped.values.reduce(0, +)
                LabeledContent("Skipped") {
                    Text(skippedCount, format: .number)
                }
                if report.reachedFileLimit {
                    Text("This project holds more files than Projects reads. It knows the others by name only.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if report.reachedNameLimit {
                    Text("This project holds more files than Projects lists. The others are left out.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if report.reachedTextLimit {
                    Text("Projects reached the most text it keeps for a project. Newer files are left out.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !skipped.isEmpty {
                    DisclosureGroup("Why Files Were Skipped", isExpanded: $showsSkipped) {
                        ForEach(skipped, id: \.url) { file in
                            LabeledContent {
                                Text(verbatim: ProjectsWindowText.skipReason(file.reason))
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(verbatim: file.url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .disclosureGroupStyle(RowDisclosureStyle())
                }
            } else {
                Text("Not indexed yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Changes whenever the counts of the report change, so the lists are read again.
    private static func fingerprint(_ report: FolderIndex.Report?) -> Int {
        guard let report else { return -1 }
        var hasher = Hasher()
        hasher.combine(report.indexed)
        hasher.combine(report.nameOnly)
        hasher.combine(report.hiddenText)
        hasher.combine(report.isIndexing)
        hasher.combine(report.skipped.values.reduce(0, +))
        return hasher.finalize()
    }
}
