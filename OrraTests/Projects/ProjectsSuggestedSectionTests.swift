import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orra

/// Suggested Projects in the Projects window with the runtime: the mail of Needs a Project
/// from the store, New Project prefilled from a suggestion, sorting again once it is
/// created, and a dismissal kept in the project list. And an opt in render of the section
/// and the prefilled sheet. The people, companies and mail are made up for these tests.
@MainActor
struct ProjectsSuggestedSectionTests {
    static let me = "me@studio.example"
    static let today = Date(timeIntervalSince1970: 1_792_411_200)

    static func message(_ id: String, from: String, name: String, subject: String, day: Double, parent: String? = nil) -> MailStore.Message {
        MailStore.Message(
            messageID: id, mailbox: nil, date: today.addingTimeInterval(day * 86_400),
            sender: MailStore.Person(name: name, address: from), to: [MailStore.Person(address: me)],
            subject: subject, inReplyTo: parent.map { [$0] } ?? [], references: parent.map { [$0] } ?? [],
            text: "Could you send the plan?", visibleText: "Could you send the plan?")
    }

    static let mail = [
        message("h1@harbor.example", from: "mei@harbor.example", name: "Mei Tan", subject: "The lobby quote", day: -9),
        message("h2@harbor.example", from: "lu@harbor.example", name: "Lu Wen", subject: "Re: The lobby quote", day: -8, parent: "h1@harbor.example"),
        message("h3@harbor.example", from: "mei@harbor.example", name: "Mei Tan", subject: "Lamps", day: -7),
        message("k1@kiln.example", from: "kai@kiln.example", name: "Kai Moss", subject: "Tiles", day: -6),
        message("k2@kiln.example", from: "kai@kiln.example", name: "Kai Moss", subject: "Glaze", day: -5),
        message("k3@kiln.example", from: "kai@kiln.example", name: "Kai Moss", subject: "Kiln schedule", day: -4),
    ]

    @Test(.timeLimit(.minutes(1)))
    func aSuggestionBecomesAProjectOnlyWithTheUsersClick() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let runtime = fixture.runtime
        let store = try #require(runtime.running?.store)
        try await store.save(Self.mail, ownAddresses: [Self.me], at: Self.today)
        let service = runtime.suggestionService()

        // The window is closed: the model is never asked, so nothing shows.
        await service.refresh()
        await service.untilNamed()
        #expect(service.suggestions.isEmpty)

        // The window holds the model, which is not on this Mac: the groups show their names in code.
        runtime.windowOpened()
        await service.refresh()
        await service.untilNamed()
        #expect(service.suggestions.map(\.name) == ["harbor.example", "kiln.example"])
        #expect(runtime.projectList.isEmpty)

        let harbor = try #require(service.suggestions.first)
        #expect(harbor.group.takes.count == 3)
        #expect(ProjectsSuggestedSection.takes(harbor) == "Emails it would take from Needs a Project: 3")
        #expect(ProjectsSuggestedSection.help(harbor) == "harbor.example\nEmails it would take from Needs a Project: 3")
        let draft = ProjectsSetupView.Draft(suggestion: harbor)
        #expect(draft.isNew)
        #expect(draft.suggestion == harbor)
        #expect(draft.name == "harbor.example")
        #expect(draft.domains == "harbor.example")
        #expect(draft.people.map(\.address) == ["mei@harbor.example", "lu@harbor.example"])
        #expect(draft.people.map(\.name) == ["Mei Tan", "Lu Wen"])
        let project = try #require(draft.project)
        #expect(project.people.map(\.address) == ["mei@harbor.example", "lu@harbor.example"])
        #expect(project.domains == ["harbor.example"])

        // Created: sorting files its mail, and the suggestion goes. The test waits until it
        // did, however long sorting takes on a busy test runner, and its time limit bounds
        // the wait.
        try await runtime.add(project)
        while await runtime.list(.project(project.id)).count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(Set(await runtime.list(.project(project.id)).map(\.messageID)) == ["h1@harbor.example", "h2@harbor.example", "h3@harbor.example"])
        await service.refresh()
        #expect(service.suggestions.map(\.name) == ["kiln.example"])

        // Dismissed: it goes at once, also from a new window, and the project list keeps a
        // hash only. The list has the dismissal before projects.json does, so the file is
        // read once the dismissal is saved, however long a busy test runner takes for it.
        let kiln = try #require(service.suggestions.first)
        let saving = ProjectsSuggestedSection.dismiss(kiln, from: service, runtime: runtime)
        #expect(service.suggestions.isEmpty)
        await saving.value
        let list = try #require(runtime.running?.list)
        #expect(list.dismissedSuggestions == [ProjectSuggestions.dismissalKey(.domain("kiln.example"))])
        let again = runtime.suggestionService()
        await again.refresh()
        await again.untilNamed()
        #expect(again.suggestions.isEmpty)
        let file = try String(contentsOf: list.file, encoding: .utf8)
        #expect(!file.contains("kiln"))
        #expect(file.contains(ProjectSuggestions.dismissalKey(.domain("kiln.example"))))

        // A dismissal needs Projects on.
        await fixture.stop()
        await #expect(throws: ProjectsRuntime.Failure.off) {
            try await runtime.dismissSuggestion(kiln.group)
        }
    }

    // MARK: Render

    /// Renders the sidebar with its suggestions and the prefilled sheet into PNG files, for
    /// reading the layout and the strings without running the app. Off unless
    /// ORRA_PROJECTS_WINDOW_SNAPSHOTS names a folder, as in ProjectsWindowViewTests. CI
    /// never sets it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_PROJECTS_WINDOW_SNAPSHOTS"] != nil))
    func renderTheSuggestions() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRA_PROJECTS_WINDOW_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let runtime = fixture.runtime
        try await runtime.running?.store.save(Self.mail, ownAddresses: [Self.me], at: Self.today)
        runtime.windowOpened()
        let model = ProjectsWindowModel(runtime: runtime)
        await model.suggestions.refresh()
        await model.suggestions.untilNamed()
        // The sidebar as the window shows it, since an offscreen split view leaves its
        // sidebar out.
        let sidebar = List {
            Section {
                Label("Needs a Project", systemImage: "tray")
                Label("Set Aside", systemImage: "archivebox")
            }
            ProjectsSuggestedSection(runtime: runtime, suggestions: model.suggestions) { _ in }
            Section("Projects") {}
        }
        .listStyle(.sidebar)
        try await render(sidebar, size: NSSize(width: 230, height: 360), to: folder.appendingPathComponent("\(language)-projects-suggestions.png"))

        let suggestion = try #require(model.suggestions.suggestions.first)
        var named = suggestion
        named.name = "Harbor lobby"
        named.description = "Renovation of the harbor office lobby, with Mei Tan of Harbor."
        named.isNamed = true
        let sheet = ProjectsSetupView(runtime: runtime, draft: ProjectsSetupView.Draft(suggestion: named), done: { _ in }, dismissSuggestion: {})
        try await render(sheet, size: NSSize(width: 560, height: 760), to: folder.appendingPathComponent("\(language)-projects-suggestion-setup.png"))
        await fixture.stop()
    }

    private func render(_ view: some View, size: NSSize, to file: URL) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        // A window that is never ordered front, so the view appears without showing.
        let offscreen = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.contentView = hosting
        for _ in 0..<40 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: file)
        offscreen.close()
    }

    /// Projects on with no project, a Mail that never runs and no model.
    @MainActor final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsSuggestedSectionTests-\(UUID().uuidString)", isDirectory: true)
        let suite = "io.github.db-ol.OrraTests.projects-suggestions-\(UUID().uuidString)"
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
                ownerOverride: { SortingService.Owner(addresses: [ProjectsSuggestedSectionTests.me]) },
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
