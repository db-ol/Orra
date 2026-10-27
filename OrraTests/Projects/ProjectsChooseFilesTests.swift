import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orra

/// Choose Files for This Email: the sheet's model with a running Projects of two indexed
/// projects, the line under Explain, the words of the change box that name a file, the rows of
/// chosen files in the list of an explanation's files, the window's part, and the renders.
/// Every file, folder and email is made up in a temporary folder, at .example addresses.
@MainActor
@Suite(.serialized)
struct ProjectsChooseFilesTests {
    typealias Fixture = ProjectsWindowViewTests.Fixture

    nonisolated static let today = Date(timeIntervalSince1970: 1_792_411_200)

    /// The fixture's project, Harbor lobby, and a second project, Kiln studio, with a plan, a
    /// drawing and notes, indexed.
    private struct Projects {
        let fixture: Fixture
        let harbor: Project
        let kiln: Project
        /// The real paths of the two projects' folders, as the index keeps their files.
        let harborFolder: URL
        let kilnFolder: URL
    }

    private static func projects(files: [(name: String, data: Data)] = []) async throws -> Projects {
        let fixture = try await Fixture(files: [("plan.dwg", Data("drawing".utf8))] + files)
        let runtime = fixture.runtime
        let harbor = try #require(runtime.projectList.first)
        let folder = fixture.root.appendingPathComponent("Kiln studio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Drawings"), withIntermediateDirectories: true)
        try "The lobby lamps hang along the north wall.".write(to: folder.appendingPathComponent("lamps-plan.md"), atomically: true, encoding: .utf8)
        try "Call notes of the kiln studio.".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try Data("drawing".utf8).write(to: folder.appendingPathComponent("Drawings/lobby.dwg"))
        let kiln = Project(name: "Kiln studio", folders: [try Project.bookmark(of: folder)])
        try await runtime.add(kiln)
        for _ in 0..<2_000 where runtime.indexReport(kiln.id).map({ $0.indexed != 2 || $0.isIndexing }) ?? true {
            try await Task.sleep(for: .milliseconds(5))
        }
        let harborFolder = try #require(await runtime.folderRoots(of: harbor.id)?.folders.first)
        let kilnFolder = try #require(await runtime.folderRoots(of: kiln.id)?.folders.first)
        return Projects(fixture: fixture, harbor: harbor, kiln: kiln, harborFolder: harborFolder, kilnFolder: kilnFolder)
    }

    /// An email of the fixture in `project`, as its list shows it.
    private static func email(_ id: String = "lamps-4@harbor.example", in project: UUID?, runtime: ProjectsRuntime) async throws -> MailStore.Listed {
        let store = try #require(runtime.running?.store)
        let text = "Hi Lin,\n\nWhere do the lobby lamps go?\n\nMei"
        try await store.save([MailStore.Message(
            messageID: id, date: today, sender: MailStore.Person(name: "Mei Tan", address: "mei@harbor.example"),
            to: [MailStore.Person(address: "me@studio.example")], subject: "Where the lamps go", text: text, visibleText: text)],
            ownAddresses: ["me@studio.example"], at: today)
        if let project {
            #expect(try await store.move(id, to: project))
        }
        return try #require(await runtime.listed(id))
    }

    private static func choice(for email: MailStore.Listed, runtime: ProjectsRuntime, model: ProjectsWindowModel) async -> ProjectsFileChoice {
        let choice = ProjectsFileChoice(email: email, runtime: runtime, emailModel: model.emailModel(for: email.messageID))
        await choice.load()
        return choice
    }

    private static func row(_ name: String, in choice: ProjectsFileChoice) throws -> ProjectsFileChoice.Row {
        try #require(choice.sections.flatMap(\.rows).first { $0.url.lastPathComponent == name })
    }

    // MARK: The sheet

    /// The email's project comes first, then the other projects by name. A search keeps the
    /// files whose names hold the text, in every project, and says when none does.
    @Test func theSheetListsTheEmailsProjectFirstAndSearchesEveryProject() async throws {
        let projects = try await Self.projects()
        defer { projects.fixture.cleanUp() }
        let runtime = projects.fixture.runtime
        let model = ProjectsWindowModel(runtime: runtime)
        let email = try await Self.email(in: projects.kiln.id, runtime: runtime)
        let choice = await Self.choice(for: email, runtime: runtime, model: model)
        #expect(choice.sections.map(\.title) == ["Kiln studio (This Email's Project)", "Harbor lobby"])
        #expect(choice.sections.map(\.kind) == [.project(projects.kiln.id), .project(projects.harbor.id)])
        let kilnFiles = Set(choice.sections[0].rows.map(\.url.lastPathComponent))
        #expect(kilnFiles == ["lamps-plan.md", "notes.txt", "lobby.dwg"])
        #expect(Set(choice.sections[1].rows.map(\.url.lastPathComponent)) == ["schedule.txt", "budget.xlsx", "plan.dwg"])
        // What the index holds of each, and the folder inside the project folder.
        let drawing = try Self.row("lobby.dwg", in: choice)
        #expect(drawing.reading == .nameOnly)
        #expect(choice.folder(of: drawing) == "Kiln studio/Drawings")
        #expect(try Self.row("lamps-plan.md", in: choice).reading == .text)
        #expect(ProjectsWindowText.listedFile(kind: ProjectsWindowText.fileKind(drawing.url), reading: drawing.reading, modified: nil, inExplanation: true) == "DWG, Name only, In this explanation")

        choice.query = "PLAN"
        #expect(Set(choice.sections.flatMap(\.rows).map(\.url.lastPathComponent)) == ["lamps-plan.md", "plan.dwg"])
        #expect(choice.sections.map(\.title) == ["Kiln studio (This Email's Project)", "Harbor lobby"])
        choice.query = "schedule"
        #expect(choice.sections.map(\.title) == ["Harbor lobby"])
        choice.query = "zzz"
        #expect(choice.sections.isEmpty)
        #expect(ProjectsWindowText.noFileNameMatches(choice.query) == "No file name matches “zzz”.")
        // An email in no project has no section of its own.
        let alone = await Self.choice(for: try await Self.email("alone@harbor.example", in: nil, runtime: runtime), runtime: runtime, model: model)
        #expect(alone.sections.map(\.title) == ["Harbor lobby", "Kiln studio"])
        await projects.fixture.stop()
    }

    /// A seventh tick stays off and says so, and an untick takes the line away. Return to
    /// Automatic Selection unticks every file, and nothing is saved before Save.
    @Test func aSeventhFileStaysOffAndSaysSo() async throws {
        let projects = try await Self.projects(files: (1...5).map { ("sheet-\($0).dwg", Data("drawing".utf8)) })
        defer { projects.fixture.cleanUp() }
        let runtime = projects.fixture.runtime
        let model = ProjectsWindowModel(runtime: runtime)
        let email = try await Self.email(in: projects.harbor.id, runtime: runtime)
        let choice = await Self.choice(for: email, runtime: runtime, model: model)
        let rows = choice.sections.flatMap(\.rows)
        #expect(rows.count == 11)
        for row in rows.prefix(6) {
            choice.toggle(row)
        }
        #expect(choice.ticks.count == ExplainPrompt.chosenFileLimit)
        #expect(ProjectsWindowText.chosenCount(choice.ticks.count) == "6 chosen, up to 6")
        choice.toggle(rows[6])
        #expect(choice.ticks.count == 6 && !choice.isTicked(rows[6]))
        #expect(choice.notice == .limit)
        #expect(ProjectsWindowText.choiceNotice(.limit) == "You can choose up to 6 files for an email.")
        choice.toggle(rows[0])
        #expect(choice.ticks.count == 5 && choice.notice == nil)
        #expect(try await runtime.running?.store.chosenFiles(of: email.messageID).isEmpty == true)
        choice.untickAll()
        #expect(choice.ticks.isEmpty)
        #expect(ProjectsWindowText.chosenCount(0) == "None chosen. Orra finds the files itself.")
        await projects.fixture.stop()
    }

    /// A dropped file is placed by its path alone: a file the index lists is ticked and
    /// shown, one inside a project folder that the index does not list says so, and one outside
    /// every folder offers its folder. None of them is opened, and none needs to be there.
    @Test func aDroppedFileIsPlacedByItsPathAlone() async throws {
        let projects = try await Self.projects()
        defer { projects.fixture.cleanUp() }
        let runtime = projects.fixture.runtime
        let model = ProjectsWindowModel(runtime: runtime)
        let email = try await Self.email(in: projects.harbor.id, runtime: runtime)
        let choice = await Self.choice(for: email, runtime: runtime, model: model)
        choice.query = "schedule"
        let kilnPlan = projects.kilnFolder.appending(path: "lamps-plan.md")
        choice.drop([kilnPlan])
        #expect(choice.ticks == [MailStore.ChosenFile(project: projects.kiln.id, path: kilnPlan.path)])
        #expect(choice.notice == .chosen("lamps-plan.md"))
        #expect(choice.scrollTarget == kilnPlan.path)
        #expect(choice.query.isEmpty)
        // In a project folder, but not read.
        choice.drop([projects.harborFolder.appending(path: "Drawings/new-plan.pdf")])
        #expect(choice.notice == .notRead("new-plan.pdf"))
        // Outside every folder.
        let elsewhere = URL(fileURLWithPath: "/Users/Shared/Elsewhere/brief.pdf")
        choice.drop([elsewhere])
        #expect(choice.notice == .outside(elsewhere))
        #expect(choice.ticks.count == 1)
        #expect(ProjectsWindowText.choiceNotice(.outside(elsewhere)) == "“brief.pdf” is not in a folder of your projects. Projects reads only the folders you add.")
        await projects.fixture.stop()
    }

    /// Add Its Folder adds the folder the user picked to the project, for all its mail, and
    /// the dropped file is chosen once the index lists it. A folder that does not hold the file
    /// is not added, and neither is a refused one.
    @Test func addingTheFolderOfADroppedFileChoosesItOnceRead() async throws {
        let projects = try await Self.projects()
        defer { projects.fixture.cleanUp() }
        let runtime = projects.fixture.runtime
        let made = projects.fixture.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        try "Brief of the lobby lamps.".write(to: made.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
        let folder = try #require(await FolderWalk.realPath(of: made))
        let dropped = folder.appending(path: "brief.md")
        let model = ProjectsWindowModel(runtime: runtime)
        let email = try await Self.email(in: projects.harbor.id, runtime: runtime)
        let choice = await Self.choice(for: email, runtime: runtime, model: model)
        choice.drop([dropped])
        #expect(choice.notice == .outside(dropped))

        await choice.addFolder(projects.kilnFolder, to: projects.harbor.id, for: dropped)
        #expect(choice.notice == .notInFolder("brief.md"))
        await choice.addFolder(FileManager.default.homeDirectoryForCurrentUser, to: projects.harbor.id, for: nil)
        #expect(choice.notice == .refused(.home))
        #expect(runtime.projectList.first { $0.id == projects.harbor.id }?.folders.count == 1)

        await choice.addFolder(folder, to: projects.harbor.id, for: dropped)
        #expect(choice.notice == .reading("brief.md"))
        #expect(choice.ticks == [MailStore.ChosenFile(project: projects.harbor.id, path: dropped.path)])
        #expect(runtime.projectList.first { $0.id == projects.harbor.id }?.folders.count == 2)
        // Chosen at once, under the files Projects has not read until the index lists it.
        #expect(choice.sections.last?.kind == .notRead)
        for _ in 0..<2_000 where runtime.indexReport(projects.harbor.id).map({ $0.indexed != 2 || $0.isIndexing }) ?? true {
            try await Task.sleep(for: .milliseconds(5))
        }
        await choice.load()
        #expect(choice.notice == .chosen("brief.md"))
        #expect(choice.sections.allSatisfy { $0.kind != .notRead })
        #expect(choice.isTicked(try Self.row("brief.md", in: choice)))
        await projects.fixture.stop()
    }

    /// Save keeps the ticks as the email's choice, and the line under Explain follows it. A
    /// save the store refuses keeps the sheet open with a line.
    @Test func saveKeepsTheChoiceAndTheLineUnderExplainFollowsIt() async throws {
        let projects = try await Self.projects()
        defer { projects.fixture.cleanUp() }
        let runtime = projects.fixture.runtime
        let model = ProjectsWindowModel(runtime: runtime)
        let email = try await Self.email(in: projects.harbor.id, runtime: runtime)
        let choice = await Self.choice(for: email, runtime: runtime, model: model)
        choice.toggle(try Self.row("plan.dwg", in: choice))
        choice.toggle(try Self.row("lamps-plan.md", in: choice))
        #expect(await choice.save())
        let emailModel = model.emailModel(for: email.messageID)
        #expect(Set(emailModel.chosenFiles.map(\.path)) == [projects.harborFolder.appending(path: "plan.dwg").path, projects.kilnFolder.appending(path: "lamps-plan.md").path])
        #expect(emailModel.choiceNote == .explainUses(2))
        #expect(ProjectsWindowText.choiceNote(.explainUses(2)) == "Explain uses the 2 files you chose.")
        // A sheet opened again starts from the saved choice.
        let again = await Self.choice(for: email, runtime: runtime, model: ProjectsWindowModel(runtime: runtime))
        #expect(Set(again.ticks) == Set(emailModel.chosenFiles))
        // An email the store does not hold keeps nothing, and the sheet says so.
        var gone = email
        gone.messageID = "gone@harbor.example"
        let refused = await Self.choice(for: gone, runtime: runtime, model: model)
        refused.toggle(try Self.row("plan.dwg", in: refused))
        #expect(await refused.save() == false)
        #expect(refused.notice == .notSaved)
        #expect(ProjectsWindowText.choiceNotice(.notSaved) == "The choice could not be saved. Try again.")
        await projects.fixture.stop()
    }

    /// The line under Explain or Explain Again: a choice before the first explanation, a
    /// choice the explanation was not made with, and none while the explanation was made with
    /// one. The same files in another order count as the same.
    @Test func theLineUnderExplainSaysWhatTheNextExplanationUses() async throws {
        let projects = try await Self.projects()
        defer { projects.fixture.cleanUp() }
        let runtime = projects.fixture.runtime
        let store = try #require(runtime.running?.store)
        let email = try await Self.email(in: nil, runtime: runtime)
        let emailModel = ProjectsEmailModel(messageID: email.messageID, actions: .live(runtime))
        await emailModel.load()
        #expect(emailModel.choiceNote == nil)
        let plan = MailStore.ChosenFile(project: projects.harbor.id, path: projects.harborFolder.appending(path: "plan.dwg").path)
        let lamps = MailStore.ChosenFile(project: projects.kiln.id, path: projects.kilnFolder.appending(path: "lamps-plan.md").path)
        #expect(await emailModel.saveChoice([plan]))
        #expect(emailModel.choiceNote == .explainUses(1))
        #expect(await emailModel.saveChoice([plan, lamps]))
        #expect(emailModel.choiceNote == .explainUses(2))

        var explanation = Explanation(
            messageID: email.messageID, project: nil, language: .en, today: Self.today, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [], questions: [], draft: .missing, draftCheck: nil, sources: [:], removed: [:], problems: [], unknownSources: [])
        explanation.chosenFiles = [lamps, plan].map { Explanation.ChosenFile(path: $0.path, project: $0.project, sources: []) }
        #expect(try await store.save(explanation, at: Self.today))
        await emailModel.load()
        #expect(emailModel.choiceNote == nil)
        #expect(await emailModel.saveChoice([lamps]))
        #expect(emailModel.choiceNote == .explainAgainUses(1))
        #expect(await emailModel.saveChoice([]))
        #expect(emailModel.choiceNote == .explainAgainGoesBack)
        explanation.chosenFiles = nil
        #expect(try await store.save(explanation, at: Self.today))
        await emailModel.load()
        #expect(emailModel.choiceNote == nil)
        #expect(ProjectsWindowText.choiceNote(.explainAgainGoesBack) == "Explain Again goes back to the automatic selection.")
        #expect(ProjectsWindowText.choiceNote(.explainAgainUses(1)) == "Explain Again uses the file you chose.")
        await projects.fixture.stop()
    }

    // MARK: The window

    /// Explain Again in the sheet saves and closes the sheet first, and the Explain that
    /// follows asks before it replaces a changed draft. Edit Project from Settings waits while
    /// the sheet shows.
    @Test func explainAgainFromTheSheetAsksFirstForAChangedDraft() async throws {
        let projects = try await Self.projects()
        defer { projects.fixture.cleanUp() }
        let runtime = projects.fixture.runtime
        let store = try #require(runtime.running?.store)
        var email = try await Self.email(in: projects.harbor.id, runtime: runtime)
        let explanation = Explanation(
            messageID: email.messageID, project: projects.harbor.id, language: .en, today: Self.today, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [], questions: [], draft: .checked(DraftCheck.Result(draft: "Hi Mei,\n\nThe lamps go along the north wall.\n\nLin", language: .en)),
            draftCheck: nil, sources: [:], removed: [:], problems: [], unknownSources: [])
        #expect(try await store.save(explanation, at: Self.today))
        #expect(try await store.save(ReviseService.Version(messageID: email.messageID, change: .tone(.warm), check: DraftCheck.Result(draft: "Dear Mei", language: .en)), startedAt: Self.today, at: Self.today) == 1)
        email = try #require(await runtime.listed(email.messageID))
        let model = ProjectsWindowModel(runtime: runtime)
        model.place = .project(projects.harbor.id)
        await model.reload()
        model.chooseFiles(for: email)
        #expect(model.choosingFiles?.id == email.messageID)
        // Edit Project from Settings waits while the sheet shows.
        model.edit(projects.harbor.id)
        #expect(model.takeProjectToEdit(presenting: false) == nil)

        model.explainFromTheSheet(email.messageID)
        #expect(model.choosingFiles == nil)
        #expect(model.selectedMessageID == email.messageID)
        await model.explainAfterTheSheet()
        #expect(model.pendingExplain == email.messageID)
        #expect(model.explaining[email.messageID] == nil)
        #expect(model.explainAfterChoosing == nil)
        await projects.fixture.stop()
    }

    // MARK: The list of an explanation's files

    /// A chosen file that gave the prompt nothing gets a row of its own, after the files the
    /// model read, with why, and a chosen name shows no excerpt.
    @Test func chosenFilesThatGaveNothingGetRowsWithWhy() {
        let project = UUID()
        let name = TextChunker.Chunk(file: URL(fileURLWithPath: "/Projects/Harbor/plan.dwg"), page: nil, modified: Self.today, heading: nil, text: "")
        var explanation = Explanation(
            messageID: "a@harbor.example", project: project, language: .en, today: Self.today, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [], questions: [], draft: .missing, draftCheck: nil,
            sources: ["F1": .file(name, origin: ExplainPrompt.FileOrigin(reason: .chosen, project: project))],
            removed: [:], problems: [], unknownSources: [])
        explanation.chosenFiles = [
            Explanation.ChosenFile(path: "/Projects/Harbor/plan.dwg", project: project, sources: ["F1"]),
            Explanation.ChosenFile(path: "/Projects/Harbor/moved.md", project: project, sources: [], missing: .notInIndex),
            Explanation.ChosenFile(path: "/Projects/Harbor/long.md", project: project, sources: [], missing: .leftOut),
        ]
        let files = ProjectsEmailFiles.files(in: explanation)
        #expect(files.map(\.url.lastPathComponent) == ["plan.dwg"])
        #expect(files.first?.isNameOnly == true)
        #expect(files.first?.reason == .chosen)
        let missing = ProjectsEmailFiles.chosenWithoutExcerpts(in: explanation)
        #expect(missing.map(\.url.lastPathComponent) == ["moved.md", "long.md"])
        #expect(missing.map(\.missing) == [.notInIndex, .leftOut])
        #expect(missing.allSatisfy { $0.excerpts.isEmpty && !$0.isNameOnly && $0.reason == .chosen && $0.project == project })
        #expect(ProjectsWindowText.chosenMissing(.notInIndex) == "Projects had not read it, so the model did not get it.")
        #expect(ProjectsWindowText.chosenMissing(.leftOut) == "Left out, as the email and its sources were too long")
    }

    // MARK: The change box

    /// The change box's words name a file by a path or a name with a known extension, a
    /// pattern on the words only.
    @Test(arguments: [
        ("/Users/lin/Plans/plan.pdf", true), ("~/Desktop/a.docx", true), ("plan-v3.dwg", true), ("用 /Users/lin/平面图.pdf 改", true),
        ("请按平面图.dwg修改", true), ("Use Plans/plan.PDF", true),
        ("send the plan by Friday", false), ("version 2.0", false), ("1.5 m", false), ("and/or the plan", false), ("1/2 of the budget", false),
        ("e.g. the lamps", false), ("Hi Mei. Thanks", false),
    ])
    func theWordsOfTheChangeBoxNameAFileByTheirPatternOnly(_ words: String, _ names: Bool) {
        #expect(ProjectsEmailModel.namesAFile(words) == names, "\(words)")
    }

    // MARK: Words

    @Test func everyLineOfTheSheetHasWords() {
        let lines = [
            ProjectsWindowText.choiceNotice(.chosen("plan.pdf")), ProjectsWindowText.choiceNotice(.notRead("plan.pdf")),
            ProjectsWindowText.choiceNotice(.reading("plan.pdf")), ProjectsWindowText.choiceNotice(.notInFolder("plan.pdf")),
            ProjectsWindowText.choiceNotice(.refused(.home)), ProjectsWindowText.choiceNotice(.projectNotSaved),
            ProjectsWindowText.reading(.text), ProjectsWindowText.reading(.recognizedText), ProjectsWindowText.reading(.waitsForRecognition),
            ProjectsWindowText.reading(.nameOnly), ProjectsWindowText.moreFiles(shown: 200, total: 340, searching: false),
            ProjectsWindowText.moreFiles(shown: 200, total: 210, searching: true), ProjectsWindowText.emailsProject("Harbor lobby"),
            ProjectsWindowText.inProject("Harbor lobby"), ProjectsWindowText.addFolder(to: "Harbor lobby"), ProjectsWindowText.addItsFolder(to: "Harbor lobby"),
            ProjectsWindowText.folderPanelMessage("Harbor lobby"), ProjectsWindowText.choiceNote(.explainUses(1)),
            ProjectsWindowText.choiceNote(.explainAgainUses(3)),
        ]
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(Set(lines).count == lines.count)
        #expect(ProjectsWindowText.choiceNotice(.chosen("plan.pdf")) == "“plan.pdf” is chosen.")
        #expect(ProjectsWindowText.choiceNotice(.refused(.home)) == "Projects never reads your home folder.")
        #expect(ProjectsWindowText.moreFiles(shown: 200, total: 340, searching: false) == "Showing the newest 200 of 340 files. Search by name to find the others.")
        #expect(ProjectsWindowText.inProject("Harbor lobby") == "In Harbor lobby")
        #expect(ProjectsWindowText.fileKind(URL(fileURLWithPath: "/a/plan.pdf")) == "PDF document")
        #expect(ProjectsWindowText.fileKind(URL(fileURLWithPath: "/a/lobby.zz9")) == "ZZ9")
        // In Chinese, from the catalog.
        let chinese = Locale(identifier: "zh-Hans")
        #expect(String(localized: LocalizedStringResource("Choose Files for This Email…", locale: chinese)) == "为这封邮件选择文件…")
        #expect(String(localized: LocalizedStringResource("Return to Automatic Selection", locale: chinese)) == "恢复自动选择")
        #expect(String(localized: LocalizedStringResource("\(2) chosen, up to \(6)", locale: chinese)) == "已选 2 个，最多 6 个")
    }

    // MARK: Render

    /// Renders the sheet and the email view's parts of a choice into PNG files, for reading
    /// the layout and the strings, with ORRA_PROJECTS_WINDOW_SNAPSHOTS as for
    /// ProjectsWindowViewTests.renderTheWindowsParts. Run it once per test language.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_PROJECTS_WINDOW_SNAPSHOTS"] != nil))
    func renderTheChoiceOfFiles() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRA_PROJECTS_WINDOW_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let projects = try await Self.projects()
        defer { projects.fixture.cleanUp() }
        let runtime = projects.fixture.runtime
        // A third project with more drawings than a section shows.
        let archive = projects.fixture.root.appendingPathComponent("Warehouse archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for number in 1...205 {
            try Data("drawing".utf8).write(to: archive.appendingPathComponent(String(format: "elevation-%03d.dwg", number)))
        }
        try await runtime.add(Project(name: "Warehouse archive", folders: [try Project.bookmark(of: archive)]))
        for _ in 0..<2_000 where (await runtime.projectFiles()).count < 211 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let store = try #require(runtime.running?.store)
        var email = try await Self.email(in: projects.harbor.id, runtime: runtime)
        let schedule = projects.harborFolder.appending(path: "schedule.txt")
        let plan = projects.harborFolder.appending(path: "plan.dwg")
        let lamps = projects.kilnFolder.appending(path: "lamps-plan.md")
        let moved = projects.harborFolder.appending(path: "Old/lamps-v1.pdf")
        // An explanation made with the schedule found by search and the Kiln plan and the
        // drawing chosen, where a chosen file had moved.
        let found = ExplainPrompt.FileOrigin(reason: .match, project: projects.harbor.id)
        let chosen = ExplainPrompt.FileOrigin(reason: .chosen, project: projects.kiln.id)
        var explanation = Explanation(
            messageID: email.messageID, project: projects.harbor.id, language: .en, today: Self.today, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [
                Explanation.Point(text: "Mei asks where the lobby lamps go.", sources: ["this email"], flags: []),
                Explanation.Point(text: "The Kiln plan hangs the lamps along the north wall.", sources: ["F1"], flags: []),
            ],
            questions: [], draft: .checked(DraftCheck.Result(draft: "Hi Mei,\n\nThe lamps go along the north wall.\n\nLin", language: .en)),
            draftCheck: nil,
            sources: [
                "this email": .message(email.messageID),
                "F1": .file(TextChunker.Chunk(file: lamps, page: nil, modified: Self.today, heading: nil, text: "The lobby lamps hang along the north wall."), origin: chosen),
                "F2": .file(TextChunker.Chunk(file: plan, page: nil, modified: Self.today, heading: nil, text: ""), origin: ExplainPrompt.FileOrigin(reason: .chosen, project: projects.harbor.id)),
                "F3": .file(TextChunker.Chunk(file: schedule, page: nil, modified: Self.today, heading: nil, text: "The lobby lamps arrive on 22 November."), origin: found),
            ],
            removed: [:], problems: [], unknownSources: [])
        explanation.chosenFiles = [
            Explanation.ChosenFile(path: lamps.path, project: projects.kiln.id, sources: ["F1"]),
            Explanation.ChosenFile(path: plan.path, project: projects.harbor.id, sources: ["F2"]),
            Explanation.ChosenFile(path: moved.path, project: projects.harbor.id, sources: [], missing: .notInIndex),
        ]
        #expect(try await store.save(explanation, at: Self.today))
        // The choice now, which the next Explain Again uses: those three and the schedule.
        #expect(try await store.saveChosenFiles([
            MailStore.ChosenFile(project: projects.kiln.id, path: lamps.path),
            MailStore.ChosenFile(project: projects.harbor.id, path: plan.path),
            MailStore.ChosenFile(project: projects.harbor.id, path: moved.path),
            MailStore.ChosenFile(project: projects.harbor.id, path: schedule.path),
        ], for: email.messageID))
        email = try #require(await runtime.listed(email.messageID))
        let model = ProjectsWindowModel(runtime: runtime)
        await model.show(email.messageID)
        let emailModel = model.emailModel(for: email.messageID)
        await emailModel.load()
        await emailModel.loadFolderRoots(for: [projects.harbor.id, projects.kiln.id])
        emailModel.showsProjectFiles = true
        emailModel.instruction = "Use /Users/lin/Plans/plan-v3.pdf for the sizes"

        // The sheet at its ideal size and at its smallest, every section of it with three
        // files a section, a search, and a dropped file outside every folder with six chosen.
        let choice = await Self.choice(for: email, runtime: runtime, model: model)
        let sheet = ProjectsChooseFiles(runtime: runtime, model: model, choice: choice)
        try await render(sheet, size: NSSize(width: 600, height: 560), to: folder.appendingPathComponent("\(language)-projects-choose-files.png"))
        try await render(sheet, size: NSSize(width: 520, height: 380), to: folder.appendingPathComponent("\(language)-projects-choose-files-small.png"))
        choice.shownPerSection = 3
        try await render(sheet, size: NSSize(width: 600, height: 1_500), to: folder.appendingPathComponent("\(language)-projects-choose-files-sections.png"))
        choice.shownPerSection = ProjectsFileChoice.sectionLimit
        choice.query = "plan"
        try await render(sheet, size: NSSize(width: 600, height: 560), to: folder.appendingPathComponent("\(language)-projects-choose-files-search.png"))
        choice.query = ""
        for row in choice.sections.flatMap(\.rows) where !choice.isTicked(row) && choice.ticks.count < ExplainPrompt.chosenFileLimit {
            choice.toggle(row)
        }
        choice.drop([URL(fileURLWithPath: "/Users/Shared/Gallery/Drawings/gallery-floor-plan.pdf")])
        try await render(sheet, size: NSSize(width: 600, height: 560), to: folder.appendingPathComponent("\(language)-projects-choose-files-outside.png"))
        try await render(sheet, size: NSSize(width: 520, height: 380), to: folder.appendingPathComponent("\(language)-projects-choose-files-outside-small.png"))

        // The email view: the line under Explain Again, the list of the explanation's files
        // with the chosen ones, and the hint under the change box.
        let area = ProjectsEmailArea(runtime: runtime, model: model, email: email)
        try await render(area, size: NSSize(width: 480, height: 640), to: folder.appendingPathComponent("\(language)-projects-email-choice.png"))
        try await render(area, size: NSSize(width: 480, height: 2_000), to: folder.appendingPathComponent("\(language)-projects-email-choice-full.png"))
        try await render(area, size: NSSize(width: 200, height: 3_600), to: folder.appendingPathComponent("\(language)-projects-email-choice-200.png"))
        // The window at its first size and at its smallest, with the email selected.
        try await render(ProjectsWindowView(runtime: runtime, model: model, openSettings: {}), size: ProjectsWindow.defaultSize, to: folder.appendingPathComponent("\(language)-projects-window-choice.png"))
        try await render(ProjectsWindowView(runtime: runtime, model: model, openSettings: {}), size: ProjectsWindow.minimumSize, to: folder.appendingPathComponent("\(language)-projects-window-760-choice.png"))
        await projects.fixture.stop()
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
}
