import AppKit
import ApplicationServices
import Observation
import OSLog
import SwiftUI
import SystemConfiguration

/// Writes the diagnostic report for Report a Problem… and opens the GitHub issue form with
/// the user's text in it. Nothing is sent: the browser shows the form, the user attaches the
/// file and submits it there, see ProblemReport.
///
/// The facts are read on the main actor, which takes a moment. The log, the crash reports,
/// the model folder's size and the file are read and written off the main actor.
@Observable
final class ProblemReporter {
    enum State: Equatable {
        case creating
        case ready(file: URL, text: String)
        case failed
    }

    private(set) var state: State = .creating
    @ObservationIgnored private let facts: () -> ProblemReport.Facts
    @ObservationIgnored private let modelFolder: URL
    @ObservationIgnored private var job: Task<Void, Never>?

    /// - Parameters:
    ///   - facts: Reads the facts. The model folder's size is filled in later.
    ///   - modelFolder: The installed speech model's folder.
    init(facts: @escaping () -> ProblemReport.Facts, modelFolder: URL) {
        self.facts = facts
        self.modelFolder = modelFolder
    }

    /// Writes a new report. Does nothing while one is being written.
    func create() {
        guard job == nil else { return }
        state = .creating
        let facts = facts()
        let modelFolder = modelFolder
        job = Task { [weak self] in
            let result = await Self.write(facts, modelFolder: modelFolder, created: Date())
            guard let self else { return }
            job = nil
            if let result {
                state = .ready(file: result.file, text: result.text)
            } else {
                state = .failed
            }
        }
    }

    /// Selects the report file in Finder, so it can be dragged into the issue.
    func showInFinder() {
        guard case .ready(let file, _) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Puts the report on the clipboard. Only when the user asks for it.
    func copyReport() {
        guard case .ready(_, let text) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens the issue form in the browser with the title, the text and the version fields
    /// filled in. When the report is attached, shows its file in Finder next to it. When
    /// the text is too long for the link, the link holds the start of it and the whole text
    /// goes on the clipboard. Never logs the text, which may be dictated.
    ///
    /// - Returns: Whether the text was cut and put on the clipboard.
    func openIssue(title: String, whatHappened: String, attachReport: Bool) -> Bool {
        let facts = facts()
        let issue = ProblemReport.issue(
            title: title,
            whatHappened: whatHappened,
            version: "\(facts.version) (\(facts.build))",
            macOS: facts.macOS,
            mac: "\(facts.model) \(facts.chip)"
        )
        if issue.wasCut {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(whatHappened.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        }
        if attachReport {
            showInFinder()
        }
        NSWorkspace.shared.open(issue.url)
        return issue.wasCut
    }

    // MARK: Off the main actor

    @concurrent
    nonisolated private static func write(_ facts: ProblemReport.Facts, modelFolder: URL, created: Date) async -> (file: URL, text: String)? {
        var facts = facts
        facts.speechModelBytes = folderSize(modelFolder)
        let log = readLog(since: created.addingTimeInterval(-60 * 60))
        let crashes = crashReports(now: created)
        facts = ProblemReport.redactDeviceNames(facts, nameParts: NSFullUserName().split(whereSeparator: \.isWhitespace).map(String.init))
        let text = redact(ProblemReport.format(facts, log: log.lines, logSource: log.source, crashReports: crashes, created: created))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(ProblemReport.fileName(for: created))
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Logger(subsystem: ProblemReport.subsystem, category: "report").error("Could not write the diagnostic report: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            return nil
        }
        return (file, text)
    }

    nonisolated private static func redact(_ text: String) -> String {
        let names = [NSUserName(), NSFullUserName()]
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return ProblemReport.redact(text, home: NSHomeDirectory(), userNames: names, computerName: computer)
    }

    nonisolated private static func folderSize(_ folder: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return FileManager.default.fileExists(atPath: folder.path) ? total : nil
    }

    /// Orra's log entries. The local log store first, which works for an app outside the
    /// sandbox when the user is an administrator. Then the log command, and last the
    /// entries of this process only.
    nonisolated private static func readLog(since: Date) -> (lines: [String], source: String) {
        let predicate = NSPredicate(format: "subsystem == %@", ProblemReport.subsystem)
        if let store = try? OSLogStore.local(), let lines = entries(in: store, since: since, predicate: predicate) {
            return (lines, "log store")
        }
        if let lines = logCommand() {
            return (lines, "log show")
        }
        if let store = try? OSLogStore(scope: .currentProcessIdentifier), let lines = entries(in: store, since: since, predicate: predicate) {
            return (lines, "this launch only")
        }
        return ([], "not readable")
    }

    nonisolated private static func entries(in store: OSLogStore, since: Date, predicate: NSPredicate) -> [String]? {
        guard let entries = try? store.getEntries(at: store.position(date: since), matching: predicate) else { return nil }
        return entries.compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return ProblemReport.logLine(date: log.date, level: level(log.level), category: log.category, message: log.composedMessage)
        }
    }

    nonisolated private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "default"
        }
    }

    nonisolated private static func logCommand() -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--predicate", "subsystem == \"\(ProblemReport.subsystem)\"", "--last", "1h", "--info", "--style", "compact"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting, so a full pipe cannot stop the command.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    nonisolated private static func crashReports(now: Date) -> [ProblemReport.CrashReport] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let files = urls.compactMap { url -> (name: String, modified: Date)? in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (url.lastPathComponent, date)
        }
        return ProblemReport.crashReportNames(files, now: now).compactMap { name in
            guard let contents = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return ProblemReport.CrashReport(name: name, contents: contents)
        }
    }

    // MARK: Facts

    /// The app's reporter, reading the facts from Orra's objects.
    static func live(
        pushToTalk: PushToTalkController,
        models: ModelInstaller,
        inputs: AudioInputList,
        feedback: RecordingFeedback,
        openAtLogin: OpenAtLogin,
        dockIcon: DockIcon,
        learning: CorrectionLearning,
        updater: AppUpdater
    ) -> ProblemReporter {
        ProblemReporter(facts: {
            let info = Bundle.main.infoDictionary ?? [:]
            let system = ProcessInfo.processInfo.operatingSystemVersion
            var macOS = "macOS \(system.majorVersion).\(system.minorVersion)"
            if system.patchVersion > 0 { macOS += ".\(system.patchVersion)" }
            if let build = sysctl("kern.osversion") { macOS += " (\(build))" }
            let microphone: String
            if let choice = pushToTalk.microphone {
                let connected = inputs.inputs.contains { $0.uid == choice.uid }
                microphone = "\(choice.name)\(connected ? "" : " (not connected)")"
            } else {
                microphone = "System default (\(inputs.defaultInput?.name ?? "none"))"
            }
            return ProblemReport.Facts(
                version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                build: info["CFBundleVersion"] as? String ?? "unknown",
                macOS: macOS,
                model: sysctl("hw.model") ?? "unknown",
                chip: sysctl("machdep.cpu.brand_string") ?? "unknown",
                memoryBytes: ProcessInfo.processInfo.physicalMemory,
                preferredLanguages: Locale.preferredLanguages,
                interfaceLanguage: Bundle.main.preferredLocalizations.first ?? "unknown",
                speechModel: models.manifest.id,
                speechModelBytes: nil,
                speechModelState: describe(models.state, pushToTalk.modelState),
                microphoneAccess: describe(pushToTalk.microphoneAccess),
                // Reads the permission only, never asks for it.
                accessibilityTrusted: AXIsProcessTrusted(),
                talkKeyActive: pushToTalk.isHotkeyActive,
                talkKeys: TalkKey.allCases.filter(pushToTalk.talkKeys.contains).map(\.rawValue),
                microphone: microphone,
                settings: [
                    .init(name: "Recording indicator", on: feedback.showsIndicator),
                    .init(name: "Sounds", on: feedback.playsSounds),
                    .init(name: "Idle bar", on: feedback.showsIdleBar),
                    .init(name: "Open at login", on: openAtLogin.isOn),
                    .init(name: "Show in Dock", on: dockIcon.showsInDock),
                    .init(name: "Learn from corrections", on: learning.isOn),
                    .init(name: "Check for updates automatically", on: updater.checksAutomatically),
                ],
                vocabularyCount: pushToTalk.vocabulary.count,
                learnedPairCount: learning.store.entries.count
            )
        }, modelFolder: ModelFolders.live.installed(.qwen3))
    }

    private static func describe(_ installer: ModelInstaller.State, _ model: PushToTalkController.ModelState) -> String {
        switch installer {
        case .checking: return "checking the files"
        case .missing(let bytes): return "not installed, \(ProblemReport.gigabytes(bytes)) downloaded"
        case .downloading(let bytes, let source): return "downloading, \(ProblemReport.gigabytes(bytes)) from \(source?.rawValue ?? "no server yet")"
        case .verifying: return "verifying"
        case .failed(let failure): return "download failed: \(failure)"
        case .installed:
            switch model {
            case .notLoaded: return "installed, not loaded"
            case .loading: return "installed, loading"
            case .ready: return "installed, loaded"
            case .unavailable(let reason): return "installed, failed to load: \(reason)"
            }
        }
    }

    private static func describe(_ access: MicrophoneAccess) -> String {
        switch access {
        case .authorized: "granted"
        case .notDetermined: "not asked yet"
        case .denied: "denied"
        case .notConfigured: "no usage description in this build"
        }
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The Report a Problem window. AppKit, like the welcome window, because an accessory app
/// cannot open a SwiftUI window from AppKit code.
final class ReportWindow {
    private let reporter: ProblemReporter
    private var window: NSWindow?

    init(reporter: ProblemReporter) {
        self.reporter = reporter
    }

    /// Writes a new report and brings the window to the front.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        reporter.create()
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: ReportView(reporter: reporter))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "Report a Problem")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

struct ReportView: View {
    let reporter: ProblemReporter
    @State private var title = ""
    @State private var whatHappened = ""
    @State private var attachesReport = true
    @State private var showsReport = false
    @State private var textWasCut = false

    private var reportReady: Bool {
        if case .ready = reporter.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What happened?")
                .font(.headline)
            TextField("Title (optional)", text: $title)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $whatHappened)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if whatHappened.isEmpty {
                    Text("What you did, what you expected, and what happened instead.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))

            Toggle("Attach the diagnostic report", isOn: $attachesReport)
            Text("It holds Orra’s version, settings, permissions and log from the last hour, facts about your Mac and recent crash reports. It holds no dictated text and no audio. Your name and your Mac’s name are taken out.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Show the report", isExpanded: $showsReport) {
                report
            }
            if attachesReport, case .failed = reporter.state {
                // Outside the report, which is hidden at first, since it keeps Continue on GitHub off.
                HStack {
                    Text("The report could not be saved. Try again, or turn off Attach the diagnostic report to go on without it.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") {
                        reporter.create()
                    }
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Reports go to GitHub and are public, so leave out private details. You need a free GitHub account. If you are not signed in, GitHub asks you to sign in or to create an account. After you sign in, GitHub shows the form with your text filled in. After creating an account, choose Continue on GitHub again if the form is empty.")
                if attachesReport {
                    Text("Orra shows the report file in Finder. Drag it into the page on GitHub.")
                }
                Text("Orra changes your clipboard only when you choose Copy Report, or when your text is too long for the link.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if textWasCut {
                Text("Your text was too long for the link, so GitHub shows only its start. The full text is on your clipboard. On GitHub, select all the text in the What happened box and paste.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Copy Report") {
                    reporter.copyReport()
                }
                .disabled(!reportReady)
                Button("Show in Finder") {
                    reporter.showInFinder()
                }
                .disabled(!reportReady)
                Spacer()
                Button("Continue on GitHub") {
                    textWasCut = reporter.openIssue(title: title, whatHappened: whatHappened, attachReport: attachesReport)
                }
                // Command-Return, since Return starts a new line in the text.
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(whatHappened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (attachesReport && !reportReady))
            }
        }
        .padding(20)
        .frame(width: 580)
        .onChange(of: whatHappened) {
            textWasCut = false
        }
    }

    @ViewBuilder private var report: some View {
        switch reporter.state {
        case .creating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Creating the report…")
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        case .ready(_, let text):
            ScrollView {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))
        case .failed:
            Text("The report could not be saved.")
        }
    }
}
