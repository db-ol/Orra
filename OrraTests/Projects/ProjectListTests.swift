import Foundation
import Testing
@testable import Orra

/// The project list in projects.json, in a temporary root, never the real Application
/// Support. The people and companies are made up for these tests, at .example addresses.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProjectListTests {
    let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectListTests-\(UUID().uuidString)", isDirectory: true))

    private func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
    }

    private func permissions(_ path: String) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func openStore() async throws -> MailStore {
        MailStore(database: try await ProjectsDatabase.open(in: storage))
    }

    private static let harbor = Project(
        name: "Harbor Lights signage",
        description: "Wayfinding signs for the Harbor Lights museum.",
        people: [Project.Person(name: "宋雨桐", address: "song.yutong@harborlights.example", role: "client")],
        domains: ["harborlights.example"],
        rules: [Project.Rule(kind: .sender, value: "desk@harborlights.example"), Project.Rule(kind: .subjectCode, value: "HL-26")],
        mailboxes: ["Work/Clients/Harbor"])

    private static let maple = Project(name: "Maple Court kitchen", people: [Project.Person(name: "Owen Pike", address: "owen@pike-build.example")])

    @Test func aMissingFileIsAnEmptyListAndChangesAreSavedForTheUserAlone() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let list = ProjectList(storage: storage)
        try await list.load()
        #expect(list.isLoaded)
        #expect(list.projects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: list.file.path))
        try await list.add(Self.harbor, mail: store)
        try await list.add(Self.maple, mail: store)
        #expect(list.file.path == storage.folder.appendingPathComponent("projects.json").path)
        #expect(try permissions(list.file.path) == 0o600)
        #expect(try permissions(storage.folder.path) == 0o700)
        // No file of the atomic write is left next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.folder.path).sorted() == ["Index", "projects.json"])

        let again = ProjectList(storage: storage)
        try await again.load()
        #expect(again.projects == [Self.harbor, Self.maple])
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: list.file)) as? [String: Any]
        #expect(stored?["version"] as? Int == ProjectList.formatVersion)

        var changed = Self.harbor
        changed.domains.append("harbor-museum.example")
        try await again.update(changed)
        await #expect(throws: ProjectList.Failure.unknownProject) {
            try await again.update(Project(name: "Unknown"))
        }
        let third = ProjectList(storage: storage)
        try await third.load()
        #expect(third.projects == [changed, Self.maple])
        #expect(third.project(Self.maple.id) == Self.maple)
        await store.close()
    }

    /// Mail can be filed in a project from the moment it is in the list.
    @Test func anAddedProjectIsRegisteredInTheMailStore() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let list = ProjectList(storage: storage)
        try await list.load()
        try await list.add(Self.harbor, mail: store)
        try await store.save([MailStore.Message(messageID: "a@test.example", date: Date(timeIntervalSince1970: 1_760_000_000), sender: MailStore.Person(address: "song.yutong@harborlights.example"), text: "Hi", visibleText: "Hi")], ownAddresses: [], at: Date(timeIntervalSince1970: 1_760_000_000))
        #expect(try await store.saveDecision(SortingDecision(project: Self.harbor.id, level: .sure, reasons: [.person]), for: "a@test.example"))
        await store.close()
    }

    @Test func aFileFromANewerOrraIsNeverWrittenOver() async throws {
        defer { cleanUp() }
        try storage.create()
        let newer = Data(#"{"version": 2, "projects": [], "folders": "a later form"}"#.utf8)
        let file = storage.folder.appendingPathComponent(ProjectList.fileName)
        try newer.write(to: file)
        let store = try await openStore()
        let list = ProjectList(storage: storage)
        await #expect(throws: ProjectList.Failure.newerFormat) {
            try await list.load()
        }
        #expect(!list.isLoaded)
        await #expect(throws: ProjectList.Failure.notLoaded) {
            try await list.add(Self.harbor, mail: store)
        }
        #expect(try Data(contentsOf: file) == newer)
        await store.close()
    }

    @Test func anUnreadableFileIsNeverWrittenOver() async throws {
        defer { cleanUp() }
        try storage.create()
        let broken = Data(#"{"version": 1, "projects": [{"name": "no id"}]}"#.utf8)
        let file = storage.folder.appendingPathComponent(ProjectList.fileName)
        try broken.write(to: file)
        let store = try await openStore()
        let list = ProjectList(storage: storage)
        await #expect(throws: (any Error).self) {
            try await list.load()
        }
        await #expect(throws: ProjectList.Failure.notLoaded) {
            try await list.add(Self.harbor, mail: store)
        }
        await #expect(throws: ProjectList.Failure.notLoaded) {
            try await list.reconcile(mail: store, index: FolderIndex(database: store.database, isDictating: { false }, watch: { _, _, _ in {} }))
        }
        #expect(try Data(contentsOf: file) == broken)
        await store.close()
    }

    /// A change that cannot be written leaves the list as the file has it, so nothing is
    /// filed in a project that the next start would not know.
    @Test func aChangeThatCannotBeSavedIsUndone() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let index = FolderIndex(database: store.database, isDictating: { false }, watch: { _, _, _ in {} })
        let list = ProjectList(storage: storage)
        try await list.load()
        try await list.add(Self.harbor, mail: store)
        // A folder in the place of the file makes every write fail.
        try FileManager.default.removeItem(at: list.file)
        try FileManager.default.createDirectory(at: list.file.appendingPathComponent("blocked", isDirectory: true), withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            try await list.add(Self.maple, mail: store)
        }
        #expect(list.projects == [Self.harbor])
        var changed = Self.harbor
        changed.description = "Changed"
        await #expect(throws: (any Error).self) {
            try await list.update(changed)
        }
        #expect(list.projects == [Self.harbor])
        await #expect(throws: (any Error).self) {
            try await list.forget(Self.harbor.id, mail: store, index: index)
        }
        #expect(list.projects == [Self.harbor])
        await store.close()
    }

    @Test func changesInARowAreWrittenInTheirOrder() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let list = ProjectList(storage: storage)
        try await list.load()
        try await list.add(Self.harbor, mail: store)
        // Changes that start before the writes before them end.
        var changes: [Task<Void, Never>] = []
        for count in 1...20 {
            var changed = Self.harbor
            changed.description = "Change \(count)"
            changes.append(Task { try? await list.update(changed) })
        }
        for change in changes {
            await change.value
        }
        #expect(list.projects.first?.description.hasPrefix("Change") == true)
        let again = ProjectList(storage: storage)
        try await again.load()
        #expect(again.projects == list.projects)
        await store.close()
    }

    @Test func forgetProjectRemovesItsMailItsIndexAndThenTheProject() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let index = FolderIndex(database: store.database, isDictating: { false }, watch: { _, _, _ in {} })
        let list = ProjectList(storage: storage)
        try await list.load()
        try await list.add(Self.harbor, mail: store)
        try await list.add(Self.maple, mail: store)
        try await store.save([MailStore.Message(messageID: "a@test.example", date: Date(timeIntervalSince1970: 1_760_000_000), sender: MailStore.Person(address: "owen@pike-build.example"), text: "Tiles", visibleText: "Tiles")], ownAddresses: [], at: Date(timeIntervalSince1970: 1_760_000_000))
        #expect(try await store.saveDecision(SortingDecision(project: Self.maple.id, level: .sure, reasons: [.person]), for: "a@test.example"))
        for project in [Self.harbor.id, Self.maple.id] {
            try await store.database.run("INSERT INTO index_files (project, path, size, modified) VALUES (?, '/tmp/a.txt', 1, 0)", [.text(project.uuidString)])
        }

        try await list.forget(Self.maple.id, mail: store, index: index)
        #expect(list.projects == [Self.harbor])
        #expect(try await store.sortingEmail("a@test.example") == nil)
        #expect(try await store.database.run("SELECT project FROM index_files") == [[.text(Self.harbor.id.uuidString)]])
        let again = ProjectList(storage: storage)
        try await again.load()
        #expect(again.projects == [Self.harbor])
        await #expect(throws: ProjectList.Failure.unknownProject) {
            try await list.forget(Self.maple.id, mail: store, index: index)
        }

        // A step that fails leaves the project in the list, to try again.
        await store.close()
        await #expect(throws: ProjectsDatabase.Failure.self) {
            try await list.forget(Self.harbor.id, mail: store, index: index)
        }
        #expect(list.projects == [Self.harbor])
    }

    @Test func reconcileRegistersTheListAndRemovesTheDataOfOtherProjects() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let index = FolderIndex(database: store.database, isDictating: { false }, watch: { _, _, _ in {} })
        let gone = UUID()
        try await store.add(project: gone)
        try await store.database.run("INSERT INTO index_files (project, path, size, modified) VALUES (?, '/tmp/a.txt', 1, 0)", [.text(gone.uuidString)])
        try storage.create()
        // projects.json came back from a backup without the database.
        try Data(#"{"version": 1, "projects": []}"#.utf8).write(to: storage.folder.appendingPathComponent(ProjectList.fileName))
        let list = ProjectList(storage: storage)
        try await list.load()
        try await list.add(Self.harbor, mail: store)
        try await store.database.run("DELETE FROM mail_projects")
        try await list.reconcile(mail: store, index: index)
        #expect(try await store.database.run("SELECT id FROM mail_projects") == [[.text(Self.harbor.id.uuidString)]])
        #expect(try await store.database.run("SELECT COUNT(*) FROM index_files").first == [.integer(0)])
        await store.close()
    }

    /// Delete All Projects Data closes the list first, so no write brings the file back.
    @Test func aClosedListWritesNothingMore() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let list = ProjectList(storage: storage)
        try await list.load()
        try await list.add(Self.harbor, mail: store)
        await list.close()
        #expect(list.projects.isEmpty)
        try await storage.deleteAll()
        await #expect(throws: ProjectList.Failure.closed) {
            try await list.update(Self.harbor)
        }
        await #expect(throws: ProjectList.Failure.closed) {
            try await list.load()
        }
        #expect(!FileManager.default.fileExists(atPath: storage.folder.path))
        await store.close()
    }

    @Test func aProjectMapsOntoSortingAndTheExplanation() {
        let candidate = Self.harbor.candidate
        #expect(candidate == SortingCandidate(
            id: Self.harbor.id, name: "Harbor Lights signage", description: "Wayfinding signs for the Harbor Lights museum.",
            people: [SortingCandidate.Person(name: "宋雨桐", address: "song.yutong@harborlights.example")],
            domains: ["harborlights.example"],
            rules: [.sender("desk@harborlights.example"), .subjectCode("HL-26")],
            mailboxes: ["Work/Clients/Harbor"]))
        #expect(Self.harbor.forExplanation == ExplainService.Project(
            id: Self.harbor.id, name: "Harbor Lights signage", description: "Wayfinding signs for the Harbor Lights museum.",
            people: [ExplainPrompt.Person(name: "宋雨桐", address: "song.yutong@harborlights.example", role: "client")],
            domains: ["harborlights.example"]))
        let rules: [SortingCandidate.Rule] = [.sender("a@b.example"), .domain("b.example"), .list("list.b.example"), .subjectCode("PO-12")]
        #expect(rules.map { Project.Rule($0).sorting } == rules)
    }

    /// A folder is kept as a plain bookmark, which still finds it after a rename.
    @Test func aFolderIsFoundAfterItIsRenamed() async throws {
        defer { cleanUp() }
        let folder = storage.root.appendingPathComponent("Signage", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try Project.bookmark(of: folder)
        let renamed = storage.root.appendingPathComponent("Signage 2026", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        let found = await Project.resolve([bookmark, Data("not a bookmark".utf8)])
        #expect(found.map { $0.resolvingSymlinksInPath().standardizedFileURL.path } == [renamed.resolvingSymlinksInPath().standardizedFileURL.path])
    }
}
