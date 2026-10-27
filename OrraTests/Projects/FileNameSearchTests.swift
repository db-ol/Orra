import Foundation
import Testing
@testable import Orra

/// Search of the project files by name and folder, over name entries written as FolderIndex
/// writes them, in a database in a temporary root. The names are made up for these tests.
struct FileNameSearchTests {
    let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("FileNameSearchTests-\(UUID().uuidString)", isDirectory: true))
    let alpha = UUID()
    let beta = UUID()

    private func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
    }

    /// Adds a file's row and its name entry: the words of its name, with hyphens and
    /// underscores as spaces and its extension as one more word, and of its folder. Returns
    /// the row's ID.
    @discardableResult
    private func add(
        _ path: String, folder: String, project: UUID, skip: String? = nil, size: Int64 = 10, to database: ProjectsDatabase
    ) async throws -> Int64 {
        try await database.transaction { database in
            try database.run(
                "INSERT INTO index_files (project, path, size, modified, skip, folder) VALUES (?, ?, ?, 1760000000, ?, ?)",
                [.text(project.uuidString), .text(path), .integer(size), skip.map { .text($0) } ?? .null, .text(folder)])
            let row = database.lastInsertedRow
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            let folderText = folder.replacingOccurrences(of: "/", with: " ")
            try database.run(
                "INSERT INTO index_file_names (rowid, name, folder) VALUES (?, ?, ?)",
                [.integer(row), .text(ChunkSearch.indexedWords(name) + " " + url.pathExtension.lowercased()), .text(ChunkSearch.indexedWords(folderText))])
            if ChunkSearch.hasChinese(name) || ChunkSearch.hasChinese(folder) {
                try database.run(
                    "INSERT INTO index_file_name_trigrams (rowid, name, folder) VALUES (?, ?, ?)",
                    [.integer(row), .text(ChunkSearch.indexedTrigramText(name)), .text(ChunkSearch.indexedTrigramText(folderText))])
            }
            return row
        }
    }

    private func names(_ text: String, in projects: [UUID]? = nil, _ database: ProjectsDatabase) async throws -> [String] {
        try await FileNameSearch(database: database).search(text, in: projects).map(\.url.lastPathComponent)
    }

    @Test func findsFilesByTheirNamesFoldersAndExtensions() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let plan = try await add("/p/Lobby/plan-v2.dwg", folder: "Lobby", project: alpha, skip: "unsupportedFormat", size: 2_048, to: database)
        try await add("/p/图纸/大厅灯具布置.dwg", folder: "图纸", project: alpha, skip: "unsupportedFormat", to: database)
        try await add("/p/Photos/IMG_2041.jpg", folder: "Photos", project: alpha, skip: "waitsForRecognition", to: database)
        try await add("/p/notes.txt", folder: "", project: alpha, to: database)
        try await add("/p/old/budget.xlsx", folder: "old", project: alpha, skip: "overFileLimit", to: database)
        #expect(try await names("plan v2", database) == ["plan-v2.dwg"])
        #expect(try await names("lobby", database) == ["plan-v2.dwg"])
        #expect(try await names("dwg", database).sorted() == ["plan-v2.dwg", "大厅灯具布置.dwg"])
        #expect(try await names("图纸", database) == ["大厅灯具布置.dwg"])
        // Three characters in a row match through the trigram table too.
        #expect(try await names("灯具布置", database) == ["大厅灯具布置.dwg"])
        #expect(try await names("IMG_2041", database) == ["IMG_2041.jpg"])
        let hit = try #require(try await FileNameSearch(database: database).search("plan").first)
        #expect(hit.file == plan && hit.project == alpha && hit.url.path == "/p/Lobby/plan-v2.dwg" && hit.size == 2_048)
        #expect(hit.modified == Date(timeIntervalSince1970: 1_760_000_000) && hit.skip == .unsupportedFormat && hit.score > 0)
        // How a row reads: text, waiting, or name only.
        let search = FileNameSearch(database: database)
        #expect(try await search.search("notes").first?.skip == nil)
        #expect(try await search.search("2041").first?.skip == .waitsForRecognition)
        #expect(try await search.search("budget").first?.skip == .overFileLimit)
        #expect(try await search.search("posters").isEmpty)
        await database.close()
    }

    /// A file's name counts four times its folder.
    @Test func aNameCountsMoreThanAFolder() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        try await add("/p/Lamps/other.pdf", folder: "Lamps", project: alpha, to: database)
        try await add("/p/Other/lamps.pdf", folder: "Other", project: alpha, to: database)
        #expect(try await names("lamps", database) == ["lamps.pdf", "other.pdf"])
        await database.close()
    }

    /// A file's whole name, with or without its extension, finds it first, also where the
    /// trigram list, which sees no number, ranks other files with the same Chinese words and
    /// a folder named like them first, and they came into the index first.
    @Test func aWholeNameFindsItsFileFirst() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        try await add("/p/现场玻璃样品/瓷砖现场玻璃1141.png", folder: "现场玻璃样品", project: alpha, skip: "waitsForRecognition", to: database)
        try await add("/p/现场玻璃样品/现场玻璃样品1142.png", folder: "现场玻璃样品", project: alpha, skip: "waitsForRecognition", to: database)
        try await add("/p/Harbor Hotel/现场玻璃0380.docx", folder: "Harbor Hotel", project: alpha, to: database)
        try await add("/p/site-plan-3.dwg", folder: "", project: alpha, skip: "unsupportedFormat", to: database)
        try await add("/p/site_plan_2.dwg", folder: "", project: alpha, skip: "unsupportedFormat", to: database)
        for (text, name) in [
            ("现场玻璃0380", "现场玻璃0380.docx"), ("现场玻璃0380.docx", "现场玻璃0380.docx"), ("site plan 3", "site-plan-3.dwg"),
            ("site-plan-2.DWG", "site_plan_2.dwg"),
        ] {
            #expect(try await names(text, database).first == name, "\(text)")
        }
        // A part of a name is no whole name.
        #expect(try await names("现场玻璃", database).count == 3)
        await database.close()
    }

    @Test func searchStaysInTheProjectsItIsGiven() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        try await add("/a/plan.dwg", folder: "", project: alpha, to: database)
        try await add("/b/plan.dwg", folder: "", project: beta, to: database)
        let search = FileNameSearch(database: database)
        #expect(try await search.search("plan", in: [alpha]).map(\.project) == [alpha])
        #expect(try await search.search("plan", in: [beta]).map(\.project) == [beta])
        #expect(try await search.search("plan").count == 2)
        #expect(try await search.search("plan", in: []).isEmpty)
        #expect(try await search.search("plan", in: [UUID()]).isEmpty)
        #expect(try await search.search("plan", limit: 0).isEmpty)
        await database.close()
    }

    /// Text from a mail can hold FTS5 syntax. Each piece stays a plain term, and a reason a
    /// later Orra wrote reads as a name only.
    @Test func hostileTermsFindOnlyThemselves() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        try await add("/p/calendars desk 合同付款.pdf", folder: "", project: alpha, skip: "aReasonOfALaterOrra", to: database)
        try await add("/p/lamps.txt", folder: "", project: alpha, to: database)
        let search = FileNameSearch(database: database)
        for term in ["calend*", "NEAR(calendars desk)", "name:calendars", "folder:lamps", "{name folder}: lamps", "\"", "AND", "(", "'; DROP TABLE index_files; --"] {
            #expect(try await search.search(term).allSatisfy { $0.url.lastPathComponent != "lamps.txt" || term.contains("lamps") }, "\(term)")
        }
        #expect(try await search.search("calend*").isEmpty)
        #expect(try await search.search("合同\"付款").first?.skip == .unsupportedFormat)
        #expect(try await database.run("SELECT count(*) FROM index_files") == [[.integer(2)]])
        await database.close()
    }
}
