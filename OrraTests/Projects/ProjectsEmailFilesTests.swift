import Foundation
import Testing
@testable import Orra

/// Why each file excerpt of an explanation was in the prompt, as the explanation saves it:
/// read by every Orra from 0.6.0 on, in both directions, also with a reason a later Orra
/// adds. And where a file is in the folders of its project now. Made up files and
/// projects, nothing from the synthetic set.
struct ProjectsEmailFilesTests {
    static let project = UUID(uuidString: "6F1D0B5E-6C1B-4C4B-9F3A-0B8E2C9D7A11")!
    static let other = UUID(uuidString: "6F1D0B5E-6C1B-4C4B-9F3A-0B8E2C9D7A12")!
    static let today = Date(timeIntervalSince1970: 1_792_411_200)

    static let schedule = TextChunker.Chunk(
        file: URL(fileURLWithPath: "/Projects/Harbor lobby/Drawings/schedule.pdf"), page: 2,
        modified: Date(timeIntervalSinceReferenceDate: 783_000_000), heading: "Lamps",
        text: "The lobby lamps arrive on 22 November.")

    /// A file source as Orra 0.6.0 saves it, without an origin.
    static let savedBefore061 = #"{"file":{"_0":{"file":"file:\/\/\/Projects\/Harbor%20lobby\/Drawings\/schedule.pdf","page":2,"modified":783000000,"heading":"Lamps","text":"The lobby lamps arrive on 22 November."}}}"#

    static func explanation(sources: [String: ExplainPrompt.Source]) -> Explanation {
        Explanation(
            messageID: "lamps-2@harbor.example", project: project, language: .en, today: today, reply: .reply(.en),
            warnings: [ExplainPrompt.Finding(warning: .documentInstruction, place: .file("F1"))],
            modelWarnings: [],
            points: [Explanation.Point(text: "The lamps arrive on 22 November.", sources: ["F1"], flags: [])],
            questions: [], draft: .missing, draftCheck: nil,
            sources: sources, removed: [:], problems: [], unknownSources: [])
    }

    private static func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: The saved origin

    /// An explanation saved before Orra 0.6.1 reads with no origin, and a file source without
    /// an origin is saved as 0.6.0 saved it, so 0.6.0 reads it too.
    @Test func anExplanationFromBefore061StillReads() throws {
        let source = try JSONDecoder().decode(ExplainPrompt.Source.self, from: Data(Self.savedBefore061.utf8))
        #expect(source == .file(Self.schedule))
        #expect(source == .file(Self.schedule, origin: nil))
        let written = try JSONEncoder().encode(ExplainPrompt.Source.file(Self.schedule))
        #expect(try Self.object(written) == Self.object(Data(Self.savedBefore061.utf8)))

        let explanation = Self.explanation(sources: ["this email": .message("lamps-2@harbor.example"), "F1": .file(Self.schedule)])
        let data = try JSONEncoder().encode(explanation)
        #expect(!String(decoding: data, as: UTF8.self).contains("origin"))
        #expect(try JSONDecoder().decode(Explanation.self, from: data) == explanation)
    }

    /// A reason this Orra does not know, as a later one may write, reads as none. The project
    /// stays, and so does the explanation around it, so Retention never drops it for that.
    @Test func aReasonFromALaterOrraReadsAsUnknown() throws {
        let later = #"{"file":{"_0":{"file":"file:\/\/\/Projects\/Harbor%20lobby\/Drawings\/schedule.pdf","page":2,"modified":783000000,"heading":"Lamps","text":"The lobby lamps arrive on 22 November."},"origin":{"reason":"pinned","project":"6F1D0B5E-6C1B-4C4B-9F3A-0B8E2C9D7A12"}}}"#
        let source = try JSONDecoder().decode(ExplainPrompt.Source.self, from: Data(later.utf8))
        #expect(source == .file(Self.schedule, origin: ExplainPrompt.FileOrigin(reason: nil, project: Self.other)))

        let explanation = Self.explanation(sources: ["F1": .file(Self.schedule, origin: ExplainPrompt.FileOrigin(reason: .match, project: Self.other))])
        let saved = String(decoding: try JSONEncoder().encode(explanation), as: UTF8.self)
        #expect(saved.contains(#""reason":"match""#))
        let read = try JSONDecoder().decode(Explanation.self, from: Data(saved.replacingOccurrences(of: #""reason":"match""#, with: #""reason":"pinned""#).utf8))
        var expected = explanation
        expected.sources["F1"] = .file(Self.schedule, origin: ExplainPrompt.FileOrigin(reason: nil, project: Self.other))
        #expect(read == expected)
    }

    /// Every reason, a reason alone, a project alone and no origin go through the store's
    /// JSON as they were.
    @Test func theOriginGoesThroughTheStoreAsItWas() throws {
        var chunks = (1...5).map { number in
            var chunk = Self.schedule
            chunk.page = number
            return chunk
        }
        chunks[4].page = nil
        let explanation = Self.explanation(sources: [
            "F1": .file(chunks[0], origin: ExplainPrompt.FileOrigin(reason: .match, project: Self.project)),
            "F2": .file(chunks[1], origin: ExplainPrompt.FileOrigin(reason: .newest, project: Self.project)),
            "F3": .file(chunks[2], origin: ExplainPrompt.FileOrigin(reason: .chosen, project: Self.other)),
            "F4": .file(chunks[3], origin: ExplainPrompt.FileOrigin(reason: nil, project: Self.other)),
            "F5": .file(chunks[4], origin: ExplainPrompt.FileOrigin(reason: .match, project: nil)),
            "F6": .file(Self.schedule),
            "this email": .message("lamps-2@harbor.example"),
            "A1": .attachment(name: "lamps.pdf", excerpt: "Twelve brass lamps."),
        ])
        // As MailStore writes and reads it.
        let read = try JSONDecoder().decode(Explanation.self, from: try JSONEncoder().encode(explanation))
        #expect(read == explanation)
    }

    // MARK: Words

    /// A file chip's popover calls its excerpt saved, with its page, since the explanation
    /// keeps the lines the hygiene took out before the model read it.
    @Test func theExcerptOfAFileSaysItIsTheSavedOne() {
        var chunk = Self.schedule
        #expect(ProjectsWindowText.savedExcerpt(chunk) == "Saved excerpt, page 2")
        chunk.page = nil
        #expect(ProjectsWindowText.savedExcerpt(chunk) == "Saved excerpt")
    }

    // MARK: Where a file is

    /// A file's folder is the project folder that holds it, the deepest when the folders
    /// nest, and the folders inside it down to the file. Names count without case, and only
    /// whole names, so a folder does not hold the files of one whose name starts with its own.
    @Test func aFilesFolderIsThePathInsideTheProjectFolderThatHoldsIt() {
        typealias Files = ProjectsEmailFiles
        let lobby = URL(fileURLWithPath: "/Users/lin/Projects/Harbor lobby", isDirectory: true)
        let drawings = lobby.appending(path: "Drawings", directoryHint: .isDirectory)
        let older = URL(fileURLWithPath: "/Users/lin/Projects/Harbor lobby old", isDirectory: true)
        let disk = URL(fileURLWithPath: "/Volumes/Work/Harbor archive", isDirectory: true)
        let roots = Files.Roots(folders: [lobby, drawings], unavailable: [disk])

        #expect(Files.place(of: drawings.appending(path: "Lamps/schedule.pdf"), in: roots) == .inFolder(name: "Drawings", path: ["Lamps"]))
        #expect(Files.place(of: lobby.appending(path: "Plans/2026/plan.pdf"), in: roots) == .inFolder(name: "Harbor lobby", path: ["Plans", "2026"]))
        #expect(Files.place(of: lobby.appending(path: "notes.md"), in: roots) == .inFolder(name: "Harbor lobby", path: []))
        #expect(Files.place(of: URL(fileURLWithPath: "/users/LIN/projects/harbor LOBBY/Plans/plan.pdf"), in: roots) == .inFolder(name: "Harbor lobby", path: ["Plans"]))
        #expect(Files.place(of: older.appending(path: "plan.pdf"), in: roots) == .outside(older))
        #expect(Files.place(of: older.appending(path: "plan.pdf"), in: Files.Roots(folders: [lobby, older])) == .inFolder(name: "Harbor lobby old", path: []))
        #expect(Files.place(of: disk.appending(path: "2025/budget.xlsx"), in: roots) == .unavailable(name: "Harbor archive", path: ["2025"]))

        let desktop = URL(fileURLWithPath: "/Users/lin/Desktop", isDirectory: true)
        #expect(Files.place(of: desktop.appending(path: "quote.pdf"), in: roots) == .outside(desktop))
        #expect(Files.place(of: desktop.appending(path: "quote.pdf"), in: Files.Roots()) == .outside(desktop))
    }
}
