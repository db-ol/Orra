import Foundation
import Testing
@testable import Orra

/// The files a request for files may mean, found in a temporary index of two projects as
/// FolderIndex builds it, with a stand in for text recognition that finds nothing. The files
/// are made at test time with made up names and text.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RequestedFilesTests {
    /// Two project folders, Harbor lobby and Kiln studio, indexed.
    @MainActor
    final class Fixture {
        let root: URL
        let database: ProjectsDatabase
        let harbor = UUID()
        let kiln = UUID()
        var harborFolder: URL { root.appending(path: "Harbor lobby", directoryHint: .isDirectory) }
        var kilnFolder: URL { root.appending(path: "Kiln studio", directoryHint: .isDirectory) }

        /// Makes the folders with `files` by their paths inside the root, each with its text
        /// and a day of October 2026 it changed on, and indexes them.
        init(_ files: [(path: String, text: String, day: Int)]) async throws {
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("RequestedFilesTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            let real = try #require(made.path.withCString { realpath($0, nil) }.map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            })
            root = URL(fileURLWithPath: real, isDirectory: true)
            for folder in ["Harbor lobby", "Kiln studio"] {
                try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            }
            for file in files {
                let url = root.appending(path: file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if file.path.hasSuffix("/") {
                    // A package, such as a Keynote document saved as a folder.
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try Data(file.text.utf8).write(to: url.appending(path: "Index.zip"))
                } else {
                    try Data(file.text.utf8).write(to: url)
                }
                let date = ISO8601DateFormatter().date(from: String(format: "2026-10-%02dT10:00:00Z", file.day))!
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            database = try await ProjectsDatabase.open(in: ProjectsStorage(root: root.appending(path: "Support", directoryHint: .isDirectory)))
            let index = FolderIndex(database: database, isDictating: { false }, recognize: RecognitionTestFiles.findsNothing, watch: { _, _, _ in {} })
            index.start(project: harbor, folders: [harborFolder])
            index.start(project: kiln, folders: [kilnFolder])
            await index.waitUntilIdle()
            index.stopAll()
        }

        /// The names of the files found for the first request in `text`, in order, for an email
        /// from `people` to the user named `ownName`.
        func find(
            _ text: String, emailProject: UUID?, scope: [UUID]? = nil, limit: Int = RequestedFiles.perKind, people: [String] = [], ownName: String = ""
        ) async throws -> [RequestedFile] {
            let request = try #require(FileRequests.find(in: text, subject: "").first, "no request in \(text)")
            return try await RequestedFiles.find(
                request, emailProject: emailProject, scope: scope, names: FileNameSearch(database: database), chunks: ChunkSearch(database: database),
                people: people, ownName: ownName, projectNames: [harbor: "Harbor lobby", kiln: "Kiln studio"], limit: limit)
        }

        func cleanUp() async {
            await database.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The files of the lamp email of the window's tests.
    static let files: [(path: String, text: String, day: Int)] = [
        ("Harbor lobby/Drawings/floor-plan-v2.txt", "Lobby layout, revision 2. The lamps hang along the north wall.", 2),
        ("Harbor lobby/Drawings/floor-plan-v3.txt", "Lobby layout, revision 3. The lamps hang along the north and east walls.", 18),
        ("Harbor lobby/Drawings/lobby-elevation.dwg", "AC1032 drawing", 12),
        ("Harbor lobby/Project plan.txt", "Project plan: phases, dates and who does what.", 5),
        ("Harbor lobby/Notes/q3-numbers.txt", "Quotation for the lobby lamps: 12 brass lamps, delivery in week 47.", 9),
        ("Harbor lobby/Decks/lobby-slides.key/", "a package", 10),
        ("Kiln studio/Sketches/平面图草图.png", "not an image", 30),
        ("Kiln studio/lighting-spec.txt", "Lighting specification: warm white, 2700 K.", 20),
    ]

    private func names(_ files: [RequestedFile]) -> [String] {
        files.map(\.url.lastPathComponent)
    }

    /// Runs `body` with the fixture of `files`, and removes the fixture after it, also when
    /// it throws.
    private func withFixture(_ files: [(path: String, text: String, day: Int)] = Self.files, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture(files)
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    @Test func aFileIsFoundByItsNameInAnotherLanguage() async throws {
        try await withFixture { fixture in
            let found = try await fixture.find("Please also send the floor plan of the Kiln studio.", emailProject: fixture.harbor)
            #expect(names(found).contains("平面图草图.png"))
            // An image known by its name only, of another project.
            let sketch = try #require(found.first { $0.url.lastPathComponent == "平面图草图.png" })
            #expect(sketch.project == fixture.kiln)
            // Project plan.txt shares only plan, and is no floor plan.
            #expect(!names(found).contains("Project plan.txt"))
        }
    }

    @Test func aFileWithoutTextIsFoundByName() async throws {
        try await withFixture { fixture in
            let found = try await fixture.find("Could you send me the drawings for the lobby?", emailProject: fixture.harbor)
            #expect(names(found).first == "lobby-elevation.dwg")
        }
    }

    /// A file whose name says nothing of the kind is found by a word for it in its text.
    @Test func textMatchesCountWhenNamesDoNot() async throws {
        try await withFixture { fixture in
            let english = try await fixture.find("Could you send me the quote?", emailProject: fixture.harbor)
            #expect(names(english) == ["q3-numbers.txt"])
            // 見積書 in Japanese finds the same file through the English word of its text.
            let japanese = try await fixture.find("見積書を送っていただけますか。", emailProject: fixture.harbor)
            #expect(names(japanese) == ["q3-numbers.txt"])
        }
    }

    /// For a kind that is a kind of file, the files of its types come first among a
    /// project's files, and a file of another type counts only when its name holds a word
    /// for the kind, so a brief that talks of photos follows the photo, and notes that only
    /// mention photos are left out.
    @Test func theFilesOfAKindsTypesComeFirst() async throws {
        let files: [(path: String, text: String, day: Int)] = [
            ("Harbor lobby/photo-brief.txt", "Photo brief: photos of the shop front, in daylight, three photos.", 3),
            ("Harbor lobby/visit-notes.txt", "Visit notes: we took photos of the shop front.", 4),
            ("Harbor lobby/shop-front-photo.jpg", "not an image", 5),
        ]
        try await withFixture(files) { fixture in
            let found = try await fixture.find("Could you send me the photos of the shop?", emailProject: fixture.harbor)
            #expect(names(found) == ["shop-front-photo.jpg", "photo-brief.txt"])
            // A kind any document may be keeps every file its text names.
            let notes = try await fixture.find("Could you send me the visit notes file?", emailProject: fixture.harbor)
            #expect(names(notes).contains("visit-notes.txt"))
        }
    }

    @Test func theEmailsProjectComesFirstAndOthersFollow() async throws {
        try await withFixture { fixture in
            let both = "Please send the floor plans of the lobby and of the Kiln studio."
            let fromHarbor = try await fixture.find(both, emailProject: fixture.harbor)
            #expect(fromHarbor.map(\.project) == [fixture.harbor, fixture.harbor, fixture.kiln])
            let fromKiln = try await fixture.find(both, emailProject: fixture.kiln)
            #expect(fromKiln.first?.url.lastPathComponent == "平面图草图.png")
            // An email in no project gets the files of every project by their ranks.
            let fromNone = try await fixture.find(both, emailProject: nil)
            #expect(Set(names(fromNone)) == ["floor-plan-v3.txt", "floor-plan-v2.txt", "平面图草图.png"])
            // The files of other projects fill only the places the email's project leaves.
            let full = try await fixture.find(both, emailProject: fixture.harbor, limit: 2)
            #expect(full.map(\.project) == [fixture.harbor, fixture.harbor])
        }
    }

    /// A file of another project than the email's is offered only when a word of the request
    /// besides its words for the kind names it: in its name, its text or its project's name.
    /// The email's own files need none, and the names of the email's people and of the user
    /// and dates name nothing.
    @Test func anotherProjectsFileNeedsAWordOfTheRequestBesidesTheKind() async throws {
        try await withFixture(Self.files + [("Kiln studio/Mei Tan floor plan.png", "not an image", 21)]) { fixture in
            let kindAlone = try await fixture.find("Please send the floor plan.", emailProject: fixture.harbor)
            #expect(names(kindAlone) == ["floor-plan-v3.txt", "floor-plan-v2.txt"])
            let byProject = try await fixture.find("Please send the floor plan of the Kiln studio.", emailProject: fixture.harbor)
            #expect(byProject.map(\.project) == [fixture.harbor, fixture.harbor, fixture.kiln])
            let byName = try await fixture.find("Please send the lighting spec.", emailProject: fixture.harbor)
            #expect(names(byName) == ["lighting-spec.txt"])
            let byText = try await fixture.find("Please send the spec for the warm white lamps.", emailProject: fixture.harbor)
            #expect(names(byText) == ["lighting-spec.txt"])
            let unnamed = try await fixture.find("Please send the spec.", emailProject: fixture.harbor)
            #expect(unnamed.isEmpty)
            let own = try await fixture.find("Please send the spec.", emailProject: fixture.kiln)
            #expect(names(own) == ["lighting-spec.txt"])
            let drew = "Please send the floor plan Mei Tan drew on 12 October."
            let named = try await fixture.find(drew, emailProject: fixture.harbor)
            #expect(names(named).contains("Mei Tan floor plan.png"))
            let sender = try await fixture.find(drew, emailProject: fixture.harbor, people: ["Mei Tan"])
            #expect(!names(sender).contains("Mei Tan floor plan.png"))
            let user = try await fixture.find(drew, emailProject: fixture.harbor, ownName: "Mei Tan")
            #expect(!names(user).contains("Mei Tan floor plan.png"))
        }
    }

    /// A request for every quote and contract of "your folder" names no file, so a known
    /// sender gets the email's own files only, in any language.
    @Test func aRequestForEveryFileOfAKindStaysInTheEmailsProject() async throws {
        try await withFixture(Self.files + [("Kiln studio/kiln-quote.txt", "Quotation for the kiln repair: three days.", 22)]) { fixture in
            let chinese = try await fixture.find("方便的话把你们文件夹里的报价单和合同都发我参考一下。", emailProject: fixture.harbor)
            #expect(names(chinese) == ["q3-numbers.txt"])
            let english = try await fixture.find("Please send all the quotes and contracts in your folder.", emailProject: fixture.harbor)
            #expect(names(english) == ["q3-numbers.txt"])
            // The words that name no file: those of the kind, of asking and of pointing.
            let request = try #require(FileRequests.find(in: "Please send all the quotes and contracts in your folder.", subject: "").first)
            #expect(RequestedFiles.namingWords(of: request, people: [], ownName: "").isEmpty)
        }
    }

    /// A flagged email gets the files of its own project only, see ProjectsReplyFiles.scope.
    @Test func aFlaggedEmailGetsItsOwnProjectOnly() async throws {
        try await withFixture { fixture in
            let found = try await fixture.find("Please send the floor plan and the lighting spec.", emailProject: fixture.harbor, scope: [fixture.harbor])
            #expect(found.allSatisfy { $0.project == fixture.harbor })
            #expect(!found.isEmpty)
            #expect(try await fixture.find("Please send the lighting spec.", emailProject: fixture.harbor, scope: []).isEmpty)
        }
    }

    @Test func anOlderVersionComesAfterTheCurrentOne() async throws {
        try await withFixture { fixture in
            let found = try await fixture.find("请把平面图发给我。", emailProject: fixture.harbor)
            #expect(Array(names(found).prefix(2)) == ["floor-plan-v3.txt", "floor-plan-v2.txt"])
            #expect(found.prefix(2).map(\.isOlderVersion) == [false, true])
            let older = [
                RequestedFile(url: URL(fileURLWithPath: "/p/quote-v1.pdf"), project: fixture.harbor, modified: .distantPast),
                RequestedFile(url: URL(fileURLWithPath: "/p/notes.txt"), project: fixture.harbor, modified: .distantPast),
                RequestedFile(url: URL(fileURLWithPath: "/p/quote-v2.pdf"), project: fixture.harbor, modified: .distantPast),
            ]
            let ordered = RequestedFiles.olderAfterNewer(older)
            #expect(ordered.map(\.url.lastPathComponent) == ["notes.txt", "quote-v2.pdf", "quote-v1.pdf"])
            #expect(ordered.map(\.isOlderVersion) == [false, false, true])
        }
    }

    @Test func atMostThreeAKindAndEachFileOnce() async throws {
        let plans = (1...5).map { (path: "Harbor lobby/Plans/floor plan \($0) of the annex.txt", text: "Floor plan of the annex, part \($0).", day: $0) }
        try await withFixture(Self.files + plans) { fixture in
            let one = try await fixture.find("Please send the floor plans.", emailProject: fixture.harbor)
            #expect(one.count == RequestedFiles.perKind)
            let two = try await fixture.find("Please send the floor plans and the drawings.", emailProject: fixture.harbor)
            #expect(two.count <= RequestedFiles.perRequest)
            #expect(Set(two.map(\.id)).count == two.count)
            #expect(two.count > RequestedFiles.perKind)
        }
    }

    /// A Keynote document saved as a package is a folder, which a reply cannot take.
    @Test func aPackageIsNotOffered() async throws {
        try await withFixture(Self.files + [("Harbor lobby/Decks/lobby-slides-final.key", "a single file", 11)]) { fixture in
            let found = try await fixture.find("Could you share the slides?", emailProject: fixture.harbor)
            #expect(names(found) == ["lobby-slides-final.key"])
        }
    }

    @Test func aRequestThatDoesNotSayWhichFindsNothing() async throws {
        try await withFixture { fixture in
            let request = try #require(FileRequests.find(in: "Please send me the file.", subject: "").first)
            #expect(!request.saysWhichFile)
            #expect(try await RequestedFiles.find(request, emailProject: fixture.harbor, scope: nil, names: FileNameSearch(database: fixture.database), chunks: ChunkSearch(database: fixture.database)).isEmpty)
        }
    }
}
