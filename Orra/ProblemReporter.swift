import AppKit
import ApplicationServices
import Observation
import OSLog
import SwiftUI
import SystemConfiguration

/// Writes the diagnostic report for Report a Problem… and opens the GitHub issue form.
/// Nothing is sent: the user attaches the file to the issue, see ProblemReport.
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

    /// Opens the issue form in the browser with the version fields filled in, and shows the
    /// file in Finder next to it.
    func openIssue() {
        let facts = facts()
        let url = ProblemReport.issueURL(
            version: "\(facts.version) (\(facts.build))",
            macOS: facts.macOS,
            mac: "\(facts.model) \(facts.chip)"
        )
        showInFinder()
        NSWorkspace.shared.open(url)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Orra creates a diagnostic report that helps find the cause. It holds Orra’s version, settings and permissions, your Mac’s model, memory, macOS version and preferred languages, the microphone’s name, Orra’s own log from the last hour and its crash reports from the last 7 days. It never holds what you dictated, recordings, the clipboard or your vocabulary. Your name and your Mac’s name are taken out. Nothing is sent.")
                .fixedSize(horizontal: false, vertical: true)
            switch reporter.state {
            case .creating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Creating the report…")
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            case .ready(_, let text):
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 280)
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color(nsColor: .separatorColor))
                Text("Open GitHub Issue opens the issue form in your browser with the versions filled in. Describe the problem there and drag the report file from Finder into the form. GitHub needs an account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") {
                        reporter.showInFinder()
                    }
                    Spacer()
                    Button("Open GitHub Issue") {
                        reporter.openIssue()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .failed:
                Text("The report could not be saved.")
                Button("Try Again") {
                    reporter.create()
                }
            }
        }
        .padding(20)
        .frame(width: 580)
    }
}
