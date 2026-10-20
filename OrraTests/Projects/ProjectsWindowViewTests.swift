import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import Orra

/// The Projects window's parts: the marks and the date of a mail row, the project setup's
/// checks of people and domains, and an opt in render of the window's parts in the test
/// language, for reading the layout and the strings without running the app.
@MainActor
struct ProjectsWindowViewTests {
    static let today = Date(timeIntervalSince1970: 1_792_411_200)

    private static func listed(level: SortingLevel?, reply: ReplyRule.Decision?, summary: String = "Could you check the quote by Friday?") -> MailStore.Listed {
        MailStore.Listed(
            messageID: "a@harbor.example", date: today,
            sender: MailStore.Person(name: "Mei Tan", address: "mei@harbor.example"),
            subject: "The quote for the lobby", project: nil, level: level, reasons: [],
            movedByUser: false, reply: reply, warnings: [], isExplained: false, hasText: true,
            summary: summary)
    }

    @Test func aRowIsMarkedWhenItNeedsAReplyOrItsProjectIsUnsure() {
        typealias Row = ProjectsWindowView.MailRow
        #expect(Row.marks(Self.listed(level: .sure, reply: .noReply(.sentByUser))).isEmpty)
        #expect(Row.marks(Self.listed(level: .sure, reply: .reply(.en))) == ["Needs reply"])
        #expect(Row.marks(Self.listed(level: .likely, reply: .reply(.zh))) == ["Needs reply", "Unsure project"])
        #expect(Row.marks(Self.listed(level: nil, reply: nil)) == ["Not sorted yet"])
        #expect(Row.marks(Self.listed(level: .unsure, reply: nil)).isEmpty)
    }

    /// Mail of today shows its time, mail of this year its day, older mail the year too.
    @Test func aRowShowsTheYearOnlyForOlderMail() throws {
        typealias Row = ProjectsWindowView.MailRow
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let english = Locale(identifier: "en_US")
        func shown(_ date: Date) -> String {
            date.formatted(Row.dateFormat(date, now: Self.today, calendar: calendar).locale(english))
        }
        // Today is 2026-10-19 at noon UTC.
        // The space before AM is a narrow one in recent ICU.
        let time = shown(Self.today.addingTimeInterval(-3_600))
        #expect(time.hasPrefix("11:00") && time.hasSuffix("AM"))
        #expect(shown(Self.today.addingTimeInterval(-86_400 * 3)) == "Oct 16")
        #expect(shown(Self.today.addingTimeInterval(-86_400 * 365)) == "Oct 19, 2025")
    }

    @Test func theSetupSaysWhyAPersonCannotBeSaved() {
        typealias Person = ProjectsSetupView.Draft.Person
        #expect(ProjectsSetupView.problem(with: Person()) == nil)
        #expect(ProjectsSetupView.problem(with: Person(name: "Mei Tan", address: "mei@harbor.example")) == nil)
        #expect(ProjectsSetupView.problem(with: Person(name: "Mei Tan")) == "Add an email address.")
        #expect(ProjectsSetupView.problem(with: Person(role: "their architect")) == "Add an email address.")
        #expect(ProjectsSetupView.problem(with: Person(address: "mei at harbor")) == "This is not an email address.")
    }

    @Test func theSetupKeepsOnlyValidPeopleAndDomains() throws {
        var draft = ProjectsSetupView.Draft()
        #expect(draft.project == nil)
        draft.name = "  Harbor  "
        draft.people = [
            ProjectsSetupView.Draft.Person(name: "Mei Tan", address: " Mei.Tan@Harbor.example ", role: "their architect"),
            ProjectsSetupView.Draft.Person(),
        ]
        draft.domains = "@Harbor.example, port.example，harbor.example"
        let project = try #require(draft.project)
        #expect(project.name == "Harbor")
        #expect(project.people == [Project.Person(name: "Mei Tan", address: "mei.tan@harbor.example", role: "their architect")])
        #expect(project.domains == ["harbor.example", "port.example"])

        draft.people.append(ProjectsSetupView.Draft.Person(name: "Lu", address: "not an address"))
        #expect(draft.validPeople == nil)
        #expect(draft.project == nil)
        draft.people.removeLast()
        draft.domains = "harbor"
        #expect(draft.validDomains == nil)
        #expect(draft.project == nil)
    }

    @Test func editingAProjectKeepsWhatTheSheetDoesNotShow() throws {
        let original = Project(
            name: "Harbor", description: "Lobby renovation",
            people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example", role: "architect")],
            domains: ["harbor.example"],
            rules: [Project.Rule(kind: .sender, value: "lu@kiln.example")],
            mailboxes: ["Work/Clients/Harbor", "Work/Archive"])
        var draft = ProjectsSetupView.Draft(original)
        #expect(!draft.isNew)
        #expect(draft.project == original)
        draft.mailbox = nil
        #expect(draft.project?.mailboxes == ["Work/Archive"])
        #expect(draft.project?.rules == original.rules)
        #expect(ProjectsSetupView.choices(["Work/Archive"], current: "Work/Clients/Harbor") == ["Work/Clients/Harbor", "Work/Archive"])
        #expect(ProjectsSetupView.choices(["Work/Archive"], current: "Work/Archive") == ["Work/Archive"])
    }

    @Test func everySkipReasonAndRefusalHasWords() {
        for reason in FileSkipReason.allCases {
            #expect(!ProjectsWindowText.skipReason(reason).isEmpty)
        }
        for refusal in [FolderWalk.Refusal.notAFolder, .home, .volumeRoot, .mailData] {
            #expect(!ProjectsWindowText.refusal(refusal).isEmpty)
        }
        #expect(ProjectsWindowText.ruleOffer(.domain("harbor.example"), project: "Harbor") == "Always file mail from @harbor.example in Harbor?")
        #expect(ProjectsWindowText.rule(.subjectCode("PO-12")) == "Mail with PO-12 in the subject")
    }

    // MARK: Render

    /// Renders the window's parts into PNG files, for reading the layout and the strings
    /// without running the app. Off unless ORRA_PROJECTS_WINDOW_SNAPSHOTS names a folder,
    /// which the test command passes as TEST_RUNNER_ORRA_PROJECTS_WINDOW_SNAPSHOTS. CI never
    /// sets it. Run it once per test language.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_PROJECTS_WINDOW_SNAPSHOTS"] != nil))
    func renderTheWindowsParts() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRA_PROJECTS_WINDOW_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let runtime = fixture.runtime
        let listModel = ProjectsWindowModel(runtime: runtime)
        listModel.notice = .selection(.stillReading)

        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach([
                Self.listed(level: .sure, reply: .reply(.en)),
                Self.listed(level: .likely, reply: .noReply(.sentByUser), summary: "The lobby lamps arrive on 22 November, two weeks later than planned."),
                Self.listed(level: nil, reply: nil, summary: ""),
            ], id: \.summary) { row in
                ProjectsWindowView.MailRow(email: row)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }
            ProjectsWindowView.RuleOfferBar(text: ProjectsWindowText.ruleOffer(.sender("mei@harbor.example"), project: "Harbor"), accept: {}, decline: {})
            ProjectsWindowView.StatusLines(runtime: runtime, model: listModel, openSettings: {})
            Spacer()
        }
        try await render(rows, size: NSSize(width: 340, height: 560), to: folder.appendingPathComponent("\(language)-projects-list.png"))

        let project = try #require(runtime.projectList.first)
        try await render(ProjectsProjectPage(runtime: runtime, project: project, edit: {}, forget: {}), size: NSSize(width: 520, height: 900), to: folder.appendingPathComponent("\(language)-projects-page.png"))

        var draft = ProjectsSetupView.Draft(project)
        draft.people.append(ProjectsSetupView.Draft.Person(name: "Lu", address: "lu at kiln"))
        draft.domains = "harbor"
        try await render(ProjectsSetupView(runtime: runtime, draft: draft) { _ in }, size: NSSize(width: 560, height: 900), to: folder.appendingPathComponent("\(language)-projects-setup.png"))

        let model = ProjectsWindowModel(runtime: runtime)
        try await render(ProjectsEmailArea(runtime: runtime, model: model, email: Self.listed(level: .sure, reply: .reply(.en))), size: NSSize(width: 520, height: 300), to: folder.appendingPathComponent("\(language)-projects-email.png"))

        let window = ProjectsWindowView(runtime: runtime, model: ProjectsWindowModel(runtime: runtime), openSettings: {})
        try await render(window, size: ProjectsWindow.defaultSize, to: folder.appendingPathComponent("\(language)-projects-window.png"))
        await fixture.stop()
    }

    private func render(_ view: some View, size: NSSize, to file: URL) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        // A window that is never ordered front, so the view appears without showing.
        let offscreen = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.contentView = hosting
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: file)
        offscreen.close()
    }

    /// Projects on with one indexed project, a Mail that never runs and no model.
    @MainActor final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsWindowViewTests-\(UUID().uuidString)", isDirectory: true)
        let suite = "io.github.db-ol.OrraTests.projects-window-\(UUID().uuidString)"
        let defaults: UserDefaults
        let projects: ProjectsSwitch
        let runtime: ProjectsRuntime

        init() async throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let storage = ProjectsStorage(root: root.appendingPathComponent("Support", isDirectory: true))
            projects = ProjectsSwitch(defaults: defaults, isVisible: true, physicalMemory: 32 << 30, storage: storage)
            projects.turnOn()
            let mail = MailBridge(
                isRunning: { false },
                permission: { _ in .mailNotRunning },
                lastPermission: { nil },
                accounts: { throw MailBridgeError.mailNotRunning },
                mailboxes: { throw MailBridgeError.mailNotRunning },
                count: { _ in throw MailBridgeError.mailNotRunning },
                listing: { _, _ in throw MailBridgeError.mailNotRunning },
                headers: { _ in throw MailBridgeError.mailNotRunning },
                source: { _ in throw MailBridgeError.mailNotRunning },
                attachments: { _ in throw MailBridgeError.mailNotRunning },
                mailbox: { _ in throw MailBridgeError.mailNotRunning },
                selection: { throw MailBridgeError.mailNotRunning },
                reply: { _, _ in throw MailBridgeError.mailNotRunning }
            )
            let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
            choice.choose([.inbox])
            choice.confirm()
            runtime = ProjectsRuntime(projects: projects, dependencies: ProjectsRuntime.Dependencies(
                storage: storage,
                bridge: mail,
                choice: choice,
                ownerOverride: { SortingService.Owner(addresses: ["me@studio.example"]) },
                language: .en,
                isDictating: { false },
                modelEnvironment: { _ in
                    ProjectsModelEnvironment(
                        startJob: { _, _ in throw RewriteError.notLoaded },
                        readSlice: { _, _ in throw RewriteError.notLoaded },
                        writeBurst: { _, _ in throw RewriteError.notLoaded },
                        endJob: { _ in throw RewriteError.notLoaded },
                        isDictating: { false },
                        captionsOn: { false },
                        memoryPressure: { .normal },
                        voiceLoaded: { false },
                        physicalMemory: 32 << 30,
                        waitUntilLoaded: { false },
                        holdModel: {},
                        releaseModel: {},
                        sleep: { try await Task.sleep(for: $0) }
                    )
                },
                modelIsInstalled: { false },
                loadTokenCounter: { nil },
                handoff: ReplyHandoff(copy: { _ in true }, mail: mail, isOrraActive: { true }, bringMailToFront: {}),
                watchesMemoryPressure: false,
                watchFolders: { _, _, _ in {} },
                sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
            ))
            runtime.follow()
            for _ in 0..<2_000 where runtime.phase != .on {
                try await Task.sleep(for: .milliseconds(5))
            }
            let folder = root.appendingPathComponent("Harbor lobby", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "The lobby lamps arrive on 22 November.".write(to: folder.appendingPathComponent("schedule.txt"), atomically: true, encoding: .utf8)
            try "x".write(to: folder.appendingPathComponent("budget.xlsx"), atomically: true, encoding: .utf8)
            try await runtime.add(Project(
                name: "Harbor lobby", description: "Renovation of the harbor office lobby. The other side writes in English.",
                folders: [try Project.bookmark(of: folder)],
                people: [Project.Person(name: "Mei Tan", address: "mei@harbor.example", role: "their architect")],
                domains: ["harbor.example"],
                rules: [Project.Rule(kind: .sender, value: "lu@kiln.example")],
                mailboxes: ["Work/Clients/Harbor"]))
            for _ in 0..<2_000 where runtime.indexReport(runtime.projectList[0].id)?.indexed != 1 {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func stop() async {
            await projects.turnOff(keepingData: false)
            for _ in 0..<2_000 where runtime.phase != .off {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
