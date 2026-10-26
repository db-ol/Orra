import AppKit
import os
import SwiftUI

/// Projects, a page of Settings shown only in builds that show Projects: the switch with what
/// Projects reads, keeps and never does, the model it works with and its download, Mail
/// access with the mailboxes Projects reads, whether the talk key's words change the draft
/// as soon as the dictation ends, and what it keeps on this Mac with a way to delete it.
///
/// While Projects is on, the page opens with Open Projects Window, and its title is Projects
/// Settings, so it is not taken for the Projects window itself. The window also opens by
/// itself once setting up is done here: when the user confirms the mailbox choice, or turns
/// Projects on with a choice confirmed before. Never at launch.
///
/// The page sits outside Orra/Projects, since it is the one place where Projects may link to
/// the privacy page and to System Settings. Code in Orra/Projects never opens a URL. The page
/// is compiled in every build, so Xcode keeps its strings in the catalog.
struct ProjectsSettings: View {
    let projects: ProjectsSwitch
    @Bindable var cleanup: TextCleanup
    /// Mail access and the mailboxes Projects reads, nil where the page is shown without
    /// them, which leaves out the parts about Mail.
    var mail: MailAccess? = nil
    /// Opens the Projects window, nil where the page is shown without it, which leaves out
    /// its button and never opens the window.
    var openWindow: (() -> Void)? = nil
    /// Opens the Projects window with Edit Project for a project, nil where the page is
    /// shown without it, which leaves out the button beside each linked mailbox.
    var editProject: ((UUID) -> Void)? = nil
    @State private var isConfirmingDelete = false
    @State private var isAskingKeepOrDelete = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if projects.isOn, let openWindow {
                WindowSection(openWindow: openWindow)
                    // Delete All Projects Data stops Projects and closes the window while
                    // the switch stays on.
                    .disabled(projects.isDeleting)
            }
            Section {
                Toggle(isOn: Binding(
                    get: { projects.isOn },
                    set: { $0 ? turnOn() : turnOff() }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Projects")
                                PreviewLabel()
                            }
                            Group {
                                Text("Reads the Mail mailboxes you choose and the folders you add. What it keeps stays on this Mac.")
                                Text("It never sends, moves or deletes mail, and never sends your mail or files anywhere.")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "briefcase")
                    }
                }
                // Off while Orra looks for the cleanup model on disk, a moment at launch,
                // since only then does it know whether turning on needs a download.
                .disabled(!projects.canTurnOn || projects.isDeleting || (!projects.isOn && !cleanup.canTurnOn))
                if !projects.hasEnoughMemory {
                    Text("Projects needs \(CleanupDefault.gigabytes(CleanupDefault.minimumMemory)) GB of memory or more. This Mac has \(projects.memoryGigabytes) GB.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link("Privacy details", destination: Self.privacyPage(for: AppLanguage.launchLocalization))
            } header: {
                Text("Sorts your mail into projects and explains each email with the files of its project.")
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent {
                    Text(verbatim: Self.modelStatus(cleanup.models.state, engine: cleanup.engineState))
                        .foregroundStyle(.secondary)
                } label: {
                    DescribedLabel(
                        title: "Cleanup model",
                        detail: "Projects works with the local model of Clean Up Text, on this Mac.",
                        systemImage: "wand.and.sparkles"
                    )
                }
                if projects.isOn {
                    ModelDownload(cleanup: cleanup)
                }
            } header: {
                Text("Model")
            }
            if projects.isOn, let mail {
                MailAccessSection(mail: mail) {
                    openURL(Self.automationSettings)
                }
                MailboxesSection(mail: mail, openWindow: openWindow, editProject: editProject)
            }
            if projects.isOn {
                Section {
                    Toggle(isOn: Binding(
                        get: { projects.revisesAfterDictation },
                        set: { projects.setRevisesAfterDictation($0) }
                    )) {
                        DescribedLabel(
                            title: "Change the draft when you finish speaking",
                            detail: "In the Projects window, put the cursor in the box where you say what to change, and use the talk key. Your words go into the box, and when you finish speaking, the draft changes. Turn this off to read your words first and then click Change Draft.",
                            systemImage: "square.and.pencil"
                        )
                    }
                } header: {
                    Text("Talk key")
                }
            }
            Section {
                LabeledContent {
                    Text(verbatim: Self.stored(projects.storedBytes))
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Stored on this Mac", systemImage: "internaldrive")
                }
                Text(verbatim: Self.retention)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if projects.deleteFailed {
                    Text("Some Projects data could not be deleted. Try again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Delete All Projects Data…", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(!holdsData || projects.isDeleting)
            } header: {
                Text("Data")
            }
        }
        .formStyle(.grouped)
        // Not Projects, the title of the Projects window, so the two are not mistaken.
        .navigationTitle("Projects Settings")
        // What Projects keeps grows while the page shows and Projects is on, as the scan
        // saves mail and the index reads folders, so the Data row looks again on its own.
        .task(id: projects.isOn) {
            await projects.followStorage()
        }
        // Lists Mail's mailboxes each time the page shows while Projects is on, and when
        // Projects turns on here.
        .task(id: projects.isOn) {
            if projects.isOn {
                await mail?.show()
            }
        }
        // Back from System Settings, where the user may have turned Mail on for Orra.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await mail?.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { note in
            if Self.isMail(note) {
                Task { await mail?.mailLaunched() }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { note in
            if Self.isMail(note) {
                Task { await mail?.refresh() }
            }
        }
        .alert("Download the cleanup model?", isPresented: $cleanup.isConfirmingProjectsDownload) {
            Button(CleanupLabels.downloadButton(cleanup.models.state, total: cleanup.models.manifest.totalBytes)) {
                downloadAndTurnOn()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Projects explains mail and drafts replies with the cleanup model. The model comes from Hugging Face or a mirror. Your mail and files stay on this Mac.")
        }
        .alert("Allow Orra to read Mail?", isPresented: Binding(
            get: { mail?.isExplaining ?? false },
            set: { mail?.isExplaining = $0 }
        )) {
            Button("Continue") {
                Task { await mail?.ask() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Projects reads mail only in the mailboxes you choose, and only while Mail is open. It never sends, moves or deletes mail. macOS asks next whether Orra may control Mail.")
        }
        .alert("Delete all Projects data?", isPresented: $isConfirmingDelete) {
            Button("Delete All", role: .destructive) {
                // The choice goes first, so a scan that still runs stops at its next look.
                mail?.choice.forget()
                Task {
                    await projects.deleteAllData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your projects with their index, mail text and drafts, and your choice of mailboxes, from this Mac. Your mail in Mail and the files in your folders stay as they are.")
        }
        .alert("Turn off Projects?", isPresented: $isAskingKeepOrDelete) {
            Button("Keep Data") {
                Task {
                    await projects.turnOff(keepingData: true)
                    turnedOff()
                }
            }
            Button("Delete Data", role: .destructive) {
                // The choice goes first, so a scan that still runs stops at its next look.
                mail?.choice.forget()
                Task {
                    await projects.turnOff(keepingData: false)
                    turnedOff()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep your projects with their index, mail text and drafts, and your choice of mailboxes, on this Mac for when you turn Projects on again, or delete them now. Your mail in Mail and the files in your folders stay as they are.")
        }
    }

    /// Turns Projects on, or asks first whether to download the cleanup model when it is
    /// not on this Mac and no download of it was agreed to, see TextCleanup.turnOnProjects.
    private func turnOn() {
        guard projects.canTurnOn, !projects.isDeleting else { return }
        if cleanup.turnOnProjects() {
            projects.turnOn()
            openWindowAfterTurningOn()
        }
    }

    /// The user agreed to the download when turning Projects on. It starts only once
    /// Projects is on.
    private func downloadAndTurnOn() {
        projects.turnOn()
        if projects.isOn {
            cleanup.confirmProjectsDownload()
            openWindowAfterTurningOn()
        } else {
            cleanup.isConfirmingProjectsDownload = false
        }
    }

    /// Opens the Projects window after the user turned Projects on here, only when they
    /// confirmed a mailbox choice before, as after turning Projects off and keeping the
    /// data, since Projects reads mail at once then. Before the first confirm, the steps
    /// that remain are on this page, so the window would only cover them. It opens then when
    /// Start Reading Mail confirms the choice.
    private func openWindowAfterTurningOn() {
        if projects.isOn, mail?.choice.isConfirmed == true {
            openWindow?()
        }
    }

    /// Whether Projects keeps anything on this Mac: data in its folder, as last measured, or
    /// the chosen mailboxes in the preferences.
    private var holdsData: Bool {
        projects.holdsData || mail?.choice.isSaved == true
    }

    /// Turning the switch off asks whether to keep or delete what Projects keeps on this Mac,
    /// and only when it keeps something.
    private func turnOff() {
        Task {
            if mail?.choice.isSaved == true {
                isAskingKeepOrDelete = true
            } else {
                isAskingKeepOrDelete = await projects.turnOffOrAsk()
            }
            if !projects.isOn {
                turnedOff()
            }
        }
    }

    /// Projects is off: a download only it agreed to stops, and the mailbox names listed
    /// for the picker leave memory.
    private func turnedOff() {
        cleanup.projectsTurnedOff()
        mail?.projectsTurnedOff()
    }

    /// Whether a notification of NSWorkspace is about Mail.
    private static func isMail(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == "com.apple.mail"
    }

    /// Where the cleanup model stands, in the words of this page. `engine` tells a model on
    /// this Mac that could not be loaded, see ModelDownload.
    static func modelStatus(_ state: ModelInstaller.State, engine: TextCleanup.EngineState = .unloaded) -> String {
        switch state {
        case .installed: engine == .failed ? String(localized: "Could not be loaded") : String(localized: "On this Mac")
        case .checking, .verifying: String(localized: "Checking…")
        case .downloading: String(localized: "Downloading…")
        case .missing, .failed: String(localized: "Not on this Mac yet")
        }
    }

    /// What stands in the way while Projects is on and the cleanup model is not on this
    /// Mac, above the button that downloads it.
    static func modelLines(_ state: ModelInstaller.State, total: Int64) -> [String] {
        switch state {
        case .missing:
            [String(localized: "Until it is, Projects cannot explain mail or draft replies.")]
        default:
            state.menuLines(total: total)
        }
    }

    /// How long Projects keeps what it read, see Retention, and that it removes old data
    /// only while it is on, so data kept while it is off stays until it is on again.
    static var retention: String {
        func days(_ period: TimeInterval) -> Int {
            Int(period / Retention.day)
        }
        return String(localized: "Projects keeps the text of each email and its explanation for \(days(Retention.mailText)) days after reading it, and a draft for \(days(Retention.drafts)) days after its last change. It keeps the rest of an email, such as its sender and subject, until \(days(Retention.emails)) days after it read the newest email of its thread. It removes old data only while it is on.")
    }

    /// What Projects keeps, in the units Finder shows, or Nothing.
    static func stored(_ bytes: Int64?) -> String {
        guard let bytes else { return String(localized: "Checking…") }
        guard bytes > 0 else { return String(localized: "Nothing") }
        return ModelInstaller.State.size(bytes)
    }

    /// The Projects window's own section at the top of the page while Projects is on, with
    /// Open Projects Window, since the projects and the mail are in that window, not here.
    private struct WindowSection: View {
        let openWindow: () -> Void

        var body: some View {
            Section {
                HStack(spacing: 12) {
                    DescribedLabel(
                        title: "Projects window",
                        detail: "Your projects, with their mail, explanations and drafts, are in a window of their own. You can also open it from the Orra menu.",
                        systemImage: "macwindow"
                    )
                    Spacer()
                    Button("Open Projects Window", action: openWindow)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
    }

    /// The privacy page in the language of Orra's interface, English for any other.
    static func privacyPage(for localization: String) -> URL {
        let name = switch localization {
        case "zh-Hans": "privacy.zh-CN.md"
        case "ja": "privacy.ja.md"
        case "es-419": "privacy.es.md"
        default: "privacy.md"
        }
        return URL(string: "https://github.com/db-ol/Orra/blob/main/docs/\(name)")!
    }

    /// Privacy & Security, Automation in System Settings, where the user turns Mail on for
    /// Orra after saying no.
    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// The word Preview in a thin capsule beside the name of Projects, since Projects may
    /// still change. The sidebar shows it under the name.
    private struct PreviewLabel: View {
        var body: some View {
            Text("Preview")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
        }
    }

    /// The cleanup model's download while Projects is on: its progress with Cancel
    /// Download while nothing else waits for it, or what stands in the way with the button
    /// that downloads it, which names the size. Once the model is on this Mac, Try Loading
    /// Again when it could not be loaded, and otherwise nothing.
    private struct ModelDownload: View {
        let cleanup: TextCleanup

        var body: some View {
            let total = cleanup.models.manifest.totalBytes
            let state = cleanup.models.state
            switch state {
            case .downloading(let bytes, let source):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(bytes), total: Double(max(total, 1))) {
                        Text(verbatim: CleanupLabels.progress(bytes: bytes, total: total))
                    } currentValueLabel: {
                        if let source {
                            Text(verbatim: String(localized: "From \(source.rawValue)"))
                        }
                    }
                    // While cleanup, translation or captions wait for the model, the cancel
                    // stays with them, since it would turn them off.
                    if cleanup.canCancelProjectsDownload {
                        Button("Cancel Download") {
                            cleanup.cancelProjectsDownload()
                        }
                    }
                }
            case .missing, .failed:
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ProjectsSettings.modelLines(state, total: total), id: \.self) { line in
                            Text(verbatim: line)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Button(CleanupLabels.downloadButton(state, total: total)) {
                        cleanup.confirmProjectsDownload()
                    }
                }
            case .verifying:
                ForEach(state.menuLines(total: total), id: \.self) { line in
                    Text(verbatim: line)
                        .foregroundStyle(.secondary)
                }
            case .installed:
                if cleanup.engineState == .failed {
                    HStack {
                        Text("Until it loads, Projects cannot explain mail or draft replies.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try Loading Again") {
                            Task { await cleanup.retryLoading() }
                        }
                    }
                }
            case .checking:
                EmptyView()
            }
        }
    }

    /// Orra's access to Mail: allowed, refused with the way to System Settings, or the
    /// button that asks.
    private struct MailAccessSection: View {
        let mail: MailAccess
        let openAutomationSettings: () -> Void

        var body: some View {
            Section {
                LabeledContent {
                    switch mail.access {
                    case .allowed:
                        Text("Allowed")
                            .foregroundStyle(.secondary)
                    case .denied:
                        Text("Not allowed")
                            .foregroundStyle(.secondary)
                    case .unknown:
                        HStack {
                            if mail.isAsking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("Allow Mail Access…") {
                                mail.allowClicked()
                            }
                            .disabled(mail.isAsking)
                        }
                    }
                } label: {
                    DescribedLabel(
                        title: "Mail access",
                        detail: "Orra reads mail in the Mail app only while Mail is open, and never opens it.",
                        systemImage: "envelope"
                    )
                }
                if let line = mail.line {
                    HStack {
                        Text(verbatim: line)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if mail.access == .denied {
                            Spacer()
                            Button("Open Automation Settings…", action: openAutomationSettings)
                        }
                    }
                }
            } header: {
                Text("Mail")
            }
        }
    }

    /// The mailboxes Projects reads, ticked one by one, the days, and Start Reading Mail,
    /// before which nothing is read. The two of all accounts show on their own, and each
    /// account's mailboxes and those On My Mac under a disclosure that is open while one of
    /// them is ticked, so the days and Start Reading Mail stay near. The mailboxes linked to
    /// a project follow, since Projects reads them too, ticked or not.
    private struct MailboxesSection: View {
        let mail: MailAccess
        /// Opens the Projects window once Start Reading Mail confirms the choice, where the
        /// mail Projects reads shows. Nil where the page is shown without the window.
        let openWindow: (() -> Void)?
        /// Opens Edit Project for the project of a linked mailbox. Nil where the page is
        /// shown without the window.
        let editProject: ((UUID) -> Void)?
        /// The groups the user opened or closed, by their place.
        @State private var expanded: [String: Bool] = [:]

        var body: some View {
            Section {
                ForEach(MailAccess.groups(mail.rows), id: \.self) { group in
                    if let place = group.place {
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded[place] ?? group.mailboxes.contains(where: mail.isChosen) },
                            set: { expanded[place] = $0 }
                        )) {
                            ForEach(group.mailboxes, id: \.self) { mailbox in
                                row(mailbox, in: place)
                            }
                        } label: {
                            Text(verbatim: place)
                        }
                        .disclosureGroupStyle(RowDisclosureStyle())
                    } else {
                        ForEach(group.mailboxes, id: \.self) { row($0, in: nil) }
                    }
                }
                if mail.isListing {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Listing the mailboxes in Mail…")
                            .foregroundStyle(.secondary)
                    }
                } else if mail.listed == nil {
                    if !mail.mailIsRunning {
                        Text("Open Mail to see its mailboxes.")
                            .foregroundStyle(.secondary)
                    } else if mail.listFailed {
                        HStack {
                            Text("Mail did not answer.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Try Again") {
                                Task { await mail.refresh() }
                            }
                        }
                    } else if mail.access != .allowed {
                        Text("Allow Mail access to see its mailboxes.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(mail.links, id: \.self) { link in
                    linkRow(link)
                }
                Picker(selection: Binding(
                    get: { mail.choice.days },
                    set: { mail.choice.choose(days: $0) }
                )) {
                    ForEach(MailChoice.dayChoices, id: \.self) { days in
                        Text("Last \(days) days").tag(days)
                    }
                } label: {
                    DescribedLabel(
                        title: "Period",
                        detail: "Projects reads only mail received within this period.",
                        systemImage: "calendar"
                    )
                }
                if mail.choice.isConfirmed {
                    Text("Projects reads mail from the chosen period in these mailboxes while Mail is open.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("Nothing is read before you click Start Reading Mail.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Start Reading Mail") {
                            if mail.startReading() {
                                openWindow?()
                            }
                        }
                        .disabled(!mail.canStartReading)
                    }
                }
            } header: {
                Text("Mailboxes")
            } footer: {
                if mail.choice.isConfirmed {
                    Text("Changes apply only to the mail Projects reads from now on. Mail it already saved stays until it expires or you delete Projects data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        /// A mailbox a project links, with its project and the button that opens Edit
        /// Project. One that Mail no longer has says so, as on the project page.
        private func linkRow(_ link: MailAccess.Link) -> some View {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: ProjectsWindowText.mailbox(link.mailbox))
                        Text(verbatim: MailAccess.note(for: link))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if link.isMissing {
                            Text("Mail has no mailbox with this name now. Choose it again in Edit Project.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } icon: {
                    Image(systemName: "link")
                }
                Spacer()
                if let editProject {
                    Button("Edit Project…") {
                        editProject(link.project)
                    }
                }
            }
        }

        /// A mailbox with its tick. A tick or an untick keeps its group open, so the group
        /// does not close under the pointer when its last mailbox is unticked.
        private func row(_ mailbox: MailMailbox, in place: String?) -> some View {
            Toggle(isOn: Binding(
                get: { mail.isChosen(mailbox) },
                set: { chosen in
                    if let place {
                        expanded[place] = true
                    }
                    mail.choose(mailbox, chosen)
                }
            )) {
                Text(verbatim: MailAccess.title(mailbox))
            }
            .toggleStyle(.checkbox)
        }
    }
}

extension ProjectsSettings {
    /// Mail access and the mailboxes Projects reads, as the page shows them, apart from the
    /// view so tests drive it with a fake Mail. AppDelegate keeps one for the app, whose
    /// MailChoice the scan reads too.
    ///
    /// - It asks macOS whether Orra may control Mail only after the user clicked Allow
    ///   Mail Access… and read Orra's explanation, and only while Mail runs. Otherwise it
    ///   shows what the bridge last learned, never a fresh check, see
    ///   MailBridge.lastPermission.
    /// - It lists Mail's mailboxes for the picker while the page shows, Projects is on and
    ///   Mail runs. The first listing after launch also learns the access, since its events
    ///   never bring up the prompt (kAEDoNotPromptForUserConsent, see MailEvents). Once one
    ///   learned that macOS has not asked the user yet (-1744), nothing is listed until the
    ///   user allows access. Their names stay in memory while Projects is on. Only the
    ///   ticked ones are saved, by MailChoice.
    /// - Start Reading Mail confirms the choice, before which the scan reads nothing
    ///   (decision 17).
    /// - It lists the mailboxes the projects link, which the scan reads along with the
    ///   ticked ones, also when they are not ticked here (MailScan). A linked one that Mail
    ///   no longer has is marked, since the scan skips it.
    @Observable
    final class MailAccess {
        /// What the page says about Orra's access to Mail.
        nonisolated enum Access: Equatable, Sendable {
            /// macOS allows Orra to control Mail.
            case allowed
            /// -1743: the user said no, or turned Mail off for Orra under Privacy &
            /// Security, Automation. Orra never asks again by itself.
            case denied
            /// Not asked yet, or not known in this run. Allow Mail Access… asks.
            case unknown
        }

        /// A mailbox a project links, with that project.
        nonisolated struct Link: Hashable, Sendable {
            /// The name the project links it with, see ProjectsRuntime.mailboxName(_:).
            let mailbox: String
            let project: UUID
            let projectName: String
            /// Whether Mail no longer has a mailbox with this name, so the scan does not
            /// read it, see ProjectsRuntime.missingMailboxes.
            var isMissing = false
        }

        /// A line under the access after the user clicked Allow Mail Access….
        nonisolated enum Note: Equatable, Sendable {
            /// Mail does not run, so nothing was asked. Orra never opens it.
            case openMailFirst
            /// macOS gave no answer in time.
            case noAnswer
        }

        let bridge: MailBridge
        /// The chosen mailboxes and days, which the scan reads.
        let choice: MailChoice
        /// Whether Mail ran at the last look.
        private(set) var mailIsRunning = false
        /// What the bridge last learned about the permission, nil before anything did.
        private(set) var permission: MailPermission?
        /// True while the page shows Orra's explanation, before macOS is asked.
        var isExplaining = false
        /// True while macOS is asked, which may wait for the user to answer its prompt.
        private(set) var isAsking = false
        private(set) var note: Note?
        /// Mail's mailboxes as listed while the page shows, nil before they are.
        private(set) var listed: [MailMailbox]?
        private(set) var isListing = false
        /// Whether the last listing failed for a reason other than access or Mail quitting.
        private(set) var listFailed = false
        @ObservationIgnored private let isOn: () -> Bool
        @ObservationIgnored private let projects: () -> [Project]
        @ObservationIgnored private let missingMailboxes: () -> Set<String>

        /// - Parameters:
        ///   - projects: the user's projects, for the mailboxes they link. The runtime's
        ///     list in the app, which is empty while Projects is off.
        ///   - missingMailboxes: the linked mailboxes Mail no longer has, the runtime's in
        ///     the app.
        ///   - isOn: whether Projects is on. Nothing is asked or listed while it is off.
        init(bridge: MailBridge, choice: MailChoice, projects: @escaping () -> [Project] = { [] }, missingMailboxes: @escaping () -> Set<String> = { [] }, isOn: @escaping () -> Bool) {
            self.bridge = bridge
            self.choice = choice
            self.projects = projects
            self.missingMailboxes = missingMailboxes
            self.isOn = isOn
        }

        var access: Access {
            Self.access(permission)
        }

        nonisolated static func access(_ permission: MailPermission?) -> Access {
            switch permission {
            case .allowed?: .allowed
            case .denied?: .denied
            case .notAsked?, .mailNotRunning?, .unknown?, nil: .unknown
            }
        }

        /// The line under the access: what to do after a click that asked nothing or got
        /// no answer, or the way to System Settings after a no.
        var line: String? {
            Self.line(access: access, note: note)
        }

        /// The access comes first, so a note from before the user answered never hides the
        /// line after a no.
        nonisolated static func line(access: Access, note: Note?) -> String? {
            switch (access, note) {
            case (.denied, _):
                String(localized: "Orra is not allowed to control Mail. Turn on Mail under Orra in Privacy & Security, Automation.")
            case (.allowed, _), (.unknown, nil):
                nil
            case (.unknown, .openMailFirst?):
                String(localized: "Open Mail first. Orra never opens it.")
            case (.unknown, .noAnswer?):
                String(localized: "macOS gave no answer. Try again.")
            }
        }

        // MARK: Access

        /// Allow Mail Access… was clicked. While Mail runs, the page shows Orra's
        /// explanation first and asks nothing yet, see `ask()`. Otherwise it says to open
        /// Mail first.
        func allowClicked() {
            mailIsRunning = bridge.isRunning()
            guard isOn(), !isAsking else { return }
            guard mailIsRunning else {
                note = .openMailFirst
                return
            }
            note = nil
            isExplaining = true
        }

        /// Continue under Orra's explanation: asks macOS whether Orra may control Mail,
        /// which shows its prompt when the user has not answered it yet. Nothing else here
        /// asks macOS. Once allowed, lists Mail's mailboxes.
        func ask() async {
            isExplaining = false
            guard isOn(), !isAsking else { return }
            mailIsRunning = bridge.isRunning()
            guard mailIsRunning else {
                note = .openMailFirst
                return
            }
            isAsking = true
            let answer = await bridge.permission(true)
            isAsking = false
            permission = bridge.lastPermission() ?? answer
            mailIsRunning = bridge.isRunning()
            switch answer {
            case .allowed:
                note = nil
                listed = nil
                await refresh()
            case .denied:
                note = nil
            case .mailNotRunning:
                note = .openMailFirst
            case .notAsked, .unknown:
                note = .noAnswer
            }
        }

        // MARK: Mailboxes

        /// The page shows: lists Mail's mailboxes again, so one added in Mail since shows
        /// too.
        func show() async {
            listed = nil
            await refresh()
        }

        /// Looks again whether Mail runs and what the bridge last learned about access,
        /// without asking macOS. Lists Mail's mailboxes when they are not listed yet, while
        /// Projects is on and Mail runs, unless a request learned that macOS has not asked
        /// the user yet (-1744). Before any request, as after launch, it lists, and the
        /// listing's events never bring up the prompt. After a no, or a question that got no
        /// answer in time, the listing shows whether the user has since allowed Orra.
        func refresh() async {
            mailIsRunning = bridge.isRunning()
            permission = bridge.lastPermission()
            dropOutdatedNote()
            guard isOn(), mailIsRunning, listed == nil, !isListing, !isAsking, permission != .notAsked else { return }
            isListing = true
            defer { isListing = false }
            do {
                let mailboxes = try await bridge.mailboxes()
                // Projects went off meanwhile, so the names are not kept.
                if isOn() {
                    listed = mailboxes
                    listFailed = false
                    Logger.projectsMail.notice("Settings listed \(mailboxes.count, privacy: .public) mailboxes")
                }
            } catch let error as MailBridgeError {
                listFailed = Self.isNoAnswer(error)
            } catch {
                // Cancelled, as when the page closes. The next look lists again.
            }
            permission = bridge.lastPermission()
            mailIsRunning = bridge.isRunning()
            dropOutdatedNote()
        }

        /// Mail started. Lists its mailboxes, and once more after a pause when Mail did not
        /// answer, as it may not while it starts.
        func mailLaunched(retryAfter pause: Duration = .seconds(3)) async {
            await refresh()
            guard listFailed else { return }
            try? await Task.sleep(for: pause)
            await refresh()
        }

        /// Drops the note under the access once it no longer holds: Mail runs again after
        /// "Open Mail first", or macOS has answered since "no answer".
        private func dropOutdatedNote() {
            if access != .unknown || (mailIsRunning && note == .openMailFirst) {
                note = nil
            }
        }

        /// Projects turned off. Forgets the mailboxes listed for the picker and what the
        /// page said, so no mailbox name stays in memory while Projects is off. The choice
        /// stays, unless the user deleted it, see MailChoice.forget().
        func projectsTurnedOff() {
            listed = nil
            listFailed = false
            note = nil
            isExplaining = false
        }

        /// Whether a listing failed for a reason the access line and the line about Mail
        /// not running do not cover.
        private nonisolated static func isNoAnswer(_ error: MailBridgeError) -> Bool {
            switch error {
            case .denied, .notAsked, .mailNotRunning: false
            case .notAnswered, .timedOut, .notFound, .changedWhileReading, .unexpectedReply, .failed: true
            }
        }

        /// The mailboxes the picker shows: those Mail listed, then the chosen ones it did
        /// not list, such as the suggestion before Mail is open or a mailbox since removed,
        /// so each can be unticked.
        var rows: [MailMailbox] {
            Self.rows(listed: listed ?? [], chosen: choice.mailboxes)
        }

        nonisolated static func rows(listed: [MailMailbox], chosen: [MailMailbox]) -> [MailMailbox] {
            var seen = Set<MailMailbox>()
            return (listed + chosen).filter { seen.insert($0).inserted }
        }

        /// The mailboxes of one place in the picker.
        nonisolated struct MailboxGroup: Hashable, Sendable {
            /// The account or On My Mac, as `place(_:)` names it, or nil for the inbox and
            /// the sent mailbox of all accounts, which show without a disclosure.
            let place: String?
            let mailboxes: [MailMailbox]
        }

        /// The rows by place, in the order each place first comes: Mail lists the two of all
        /// accounts first, then each account's mailboxes, then those On My Mac.
        nonisolated static func groups(_ rows: [MailMailbox]) -> [MailboxGroup] {
            var places: [String?] = []
            var mailboxes: [String?: [MailMailbox]] = [:]
            for mailbox in rows {
                let place = place(mailbox)
                if mailboxes[place] == nil {
                    places.append(place)
                }
                mailboxes[place, default: []].append(mailbox)
            }
            return places.map { MailboxGroup(place: $0, mailboxes: mailboxes[$0] ?? []) }
        }

        func isChosen(_ mailbox: MailMailbox) -> Bool {
            choice.mailboxes.contains(mailbox)
        }

        /// The mailboxes the projects link, each with its project, in the order of the
        /// projects and their mailboxes.
        var links: [Link] {
            Self.links(projects(), missing: missingMailboxes())
        }

        nonisolated static func links(_ projects: [Project], missing: Set<String>) -> [Link] {
            projects.flatMap { project in
                project.mailboxes.map { Link(mailbox: $0, project: project.id, projectName: project.name, isMissing: missing.contains($0)) }
            }
        }

        /// The line under a linked mailbox.
        nonisolated static func note(for link: Link) -> String {
            String(localized: "Also read for “\(link.projectName)”")
        }

        /// Ticks or unticks a mailbox, which MailChoice saves at once. Only ticked mailboxes
        /// are saved.
        func choose(_ mailbox: MailMailbox, _ chosen: Bool) {
            if chosen {
                guard !isChosen(mailbox) else { return }
                choice.choose(choice.mailboxes + [mailbox])
            } else {
                choice.choose(choice.mailboxes.filter { $0 != mailbox })
            }
        }

        /// Whether Start Reading Mail can confirm the choice: Projects is on, Orra may read
        /// Mail, at least one mailbox is ticked, and the choice is not confirmed yet.
        var canStartReading: Bool {
            isOn() && access == .allowed && !choice.mailboxes.isEmpty && !choice.isConfirmed
        }

        /// Start Reading Mail: confirms the choice, after which the scan reads the chosen
        /// mailboxes while Mail runs. Returns whether it confirmed, so the page opens the
        /// Projects window, where the mail shows.
        @discardableResult
        func startReading() -> Bool {
            guard canStartReading else { return false }
            choice.confirm()
            Logger.projectsMail.notice("Mail choice confirmed: \(self.choice.mailboxes.count, privacy: .public) mailboxes, \(self.choice.days, privacy: .public) days")
            return true
        }

        /// A mailbox's name in the picker: the inbox and the sent mailbox of all accounts in
        /// the user's language, any other by its name in Mail.
        nonisolated static func title(_ mailbox: MailMailbox) -> String {
            switch mailbox.kind {
            case .inbox: String(localized: "Inbox (all accounts)")
            case .sent: String(localized: "Sent (all accounts)")
            case .mailbox: mailbox.name
            }
        }

        /// Where a mailbox sits, its account or On My Mac, under its name. Nil for the two
        /// of all accounts.
        nonisolated static func place(_ mailbox: MailMailbox) -> String? {
            guard mailbox.kind == .mailbox else { return nil }
            return mailbox.account ?? String(localized: "On My Mac")
        }
    }
}
