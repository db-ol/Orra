import Foundation
import Synchronization
import Testing
@testable import Orra

/// The files of a reply in a temporary tree: what a ticked file keeps, and how the check
/// right before the reply finds it again, follows a rename only to the same file, and
/// refuses a file that changed, went or left the folders of its projects. Nothing here
/// opens a file.
struct ReplyFilesTests {
    private static let harbor = UUID(uuidString: "6F1D0B5E-6C1B-4C4B-9F3A-0B8E2C9D7A11")!
    private static let kiln = UUID(uuidString: "2B7C4E91-0D3A-4F6B-8E25-7A1C9D3B5F40")!

    // MARK: Ticking

    @Test func aTickedFileKeepsItsRealPathItsProjectsAndItsIdentity() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let file = try tree.file("Harbor/Drawings/floor-plan-v3.pdf", "plan v3")
        let modified = Date(timeIntervalSince1970: 1_760_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let roots = [Self.harbor: [tree.url("Harbor")], Self.kiln: [tree.url("Harbor/Drawings")]]
        let ticked = try await ReplyFiles.file(at: file, roots: { roots }, first: Self.kiln).get()
        #expect(ticked.url.path == tree.real("Harbor/Drawings/floor-plan-v3.pdf"))
        #expect(ticked.id == ticked.url.path)
        #expect(ticked.projects == [Self.kiln, Self.harbor])
        #expect(ticked.size == 7)
        #expect(ticked.modified == modified)

        let again = try await ReplyFiles.file(at: file, roots: { roots }).get()
        #expect(again.projects == [Self.kiln, Self.harbor].sorted { $0.uuidString < $1.uuidString })
        #expect(again.identity == ticked.identity)
    }

    @Test func aFileOutsideEveryFolderOfAProjectIsRefused() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let file = try tree.file("Downloads/floor-plan-v3.pdf")
        try tree.folder("Harbor")
        let roots = [Self.harbor: [tree.url("Harbor")]]
        #expect(await ReplyFiles.file(at: file, roots: { roots }) == .failure(.notInAddedFolder))
        #expect(await ReplyFiles.file(at: file, roots: { [:] }) == .failure(.notInAddedFolder))
        // A folder whose name only starts like the project's is another folder.
        let neighbor = try tree.file("Harbor lobby/plan.pdf")
        #expect(await ReplyFiles.file(at: neighbor, roots: { roots }) == .failure(.notInAddedFolder))
    }

    @Test func aFolderOrAPackageIsRefused() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file("Harbor/Slides.key/Index.zip")
        let roots = [Self.harbor: [tree.url("Harbor")]]
        #expect(await ReplyFiles.file(at: tree.url("Harbor/Slides.key"), roots: { roots }) == .failure(.package))
        #expect(await ReplyFiles.file(at: tree.url("Harbor"), roots: { roots }) == .failure(.package))
    }

    @Test func aMissingFileOrAnotherURLIsRefused() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.folder("Harbor")
        let roots = [Self.harbor: [tree.url("Harbor")]]
        #expect(await ReplyFiles.file(at: tree.url("Harbor/gone.pdf"), roots: { roots }) == .failure(.moved))
        let web = try #require(URL(string: "https://harbor.example/plan.pdf"))
        #expect(await ReplyFiles.file(at: web, roots: { roots }) == .failure(.moved))
    }

    /// A link counts where it leads: a link in the folder to a file outside it is a file
    /// outside, and a link to a file inside is that file at its own path.
    @Test func aLinkCountsWhereItLeads() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file("Private/salaries.xlsx")
        try tree.file("Harbor/Drawings/floor-plan-v3.pdf")
        try tree.link("Harbor/salaries.xlsx", to: tree.url("Private/salaries.xlsx").path)
        try tree.link("Harbor/plan.pdf", to: "Drawings/floor-plan-v3.pdf")
        let roots = [Self.harbor: [tree.url("Harbor")]]
        #expect(await ReplyFiles.file(at: tree.url("Harbor/salaries.xlsx"), roots: { roots }) == .failure(.notInAddedFolder))
        let plan = try await ReplyFiles.file(at: tree.url("Harbor/plan.pdf"), roots: { roots }).get()
        #expect(plan.url.path == tree.real("Harbor/Drawings/floor-plan-v3.pdf"))
    }

    @Test func aFileNotOnThisMacIsRefused() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let file = try tree.file("Harbor/plan.pdf")
        let roots = [Self.harbor: [tree.url("Harbor")]]
        #expect(await ReplyFiles.file(at: file, roots: { roots }, isDownloaded: { _ in false }) == .failure(.notDownloaded))
        let ticked = try await ReplyFiles.file(at: file, roots: { roots }).get()
        #expect(await ReplyFiles.recheck(ticked, roots: { roots }, isDownloaded: { _ in false }) == .failure(.notDownloaded))
    }

    // MARK: The check before the reply

    @Test func anUnchangedFileGoesAsItIs() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let roots = [Self.harbor: [tree.url("Harbor")]]
        let ticked = try await ReplyFiles.file(at: try tree.file("Harbor/plan.pdf"), roots: { roots }).get()
        #expect(await ReplyFiles.recheck(ticked, roots: { roots }) == .success(ticked))
    }

    /// A rename on the volume keeps the file's number, size and date, so the check finds the
    /// same file at its new place, in its folder or another one of a project.
    @Test func aRenamedFileIsTakenFromItsNewPlace() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let roots = [Self.harbor: [tree.url("Harbor")], Self.kiln: [tree.url("Kiln")]]
        try tree.folder("Kiln/Sketches")
        let ticked = try await ReplyFiles.file(at: try tree.file("Harbor/Drawings/floor-plan-v3.pdf"), roots: { roots }).get()
        try tree.move("Harbor/Drawings/floor-plan-v3.pdf", to: "Harbor/Drawings/floor-plan-v3-final.pdf")
        let renamed = try await ReplyFiles.recheck(ticked, roots: { roots }).get()
        #expect(renamed.url.path == tree.real("Harbor/Drawings/floor-plan-v3-final.pdf"))
        #expect(renamed.identity == ticked.identity)
        #expect(renamed.projects == [Self.harbor])

        try tree.move("Harbor/Drawings/floor-plan-v3-final.pdf", to: "Kiln/Sketches/plan.pdf")
        let moved = try await ReplyFiles.recheck(renamed, roots: { roots }).get()
        #expect(moved.url.path == tree.real("Kiln/Sketches/plan.pdf"))
        #expect(moved.projects == [Self.kiln])
    }

    @Test func aFileMovedOutOfTheFoldersOfEveryProjectIsRefused() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let roots = [Self.harbor: [tree.url("Harbor")]]
        try tree.folder("Elsewhere")
        let ticked = try await ReplyFiles.file(at: try tree.file("Harbor/plan.pdf"), roots: { roots }).get()
        try tree.move("Harbor/plan.pdf", to: "Elsewhere/plan.pdf")
        #expect(await ReplyFiles.recheck(ticked, roots: { roots }) == .failure(.notInAddedFolder))
    }

    @Test func aDeletedFileIsMoved() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let roots = [Self.harbor: [tree.url("Harbor")]]
        let ticked = try await ReplyFiles.file(at: try tree.file("Harbor/plan.pdf"), roots: { roots }).get()
        try FileManager.default.removeItem(at: tree.url("Harbor/plan.pdf"))
        #expect(await ReplyFiles.recheck(ticked, roots: { roots }) == .failure(.moved))
    }

    /// Another file at the path, with the same name, size and content, is not the file the
    /// user ticked, and neither is a file that takes the name after the first went. Nothing
    /// follows a name or a number that another file may hold now.
    @Test func anotherFileInThePlaceOfTheTickedOneIsNotTaken() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let roots = [Self.harbor: [tree.url("Harbor")]]
        let ticked = try await ReplyFiles.file(at: try tree.file("Harbor/plan.pdf", "same"), roots: { roots }).get()
        try FileManager.default.removeItem(at: tree.url("Harbor/plan.pdf"))
        try tree.file("Harbor/plan.pdf", "same")
        #expect(await ReplyFiles.recheck(ticked, roots: { roots }) == .failure(.changed))

        let renamedOver = try await ReplyFiles.file(at: tree.url("Harbor/plan.pdf"), roots: { roots }).get()
        try tree.file("Harbor/plan-new.pdf", "same")
        try FileManager.default.removeItem(at: tree.url("Harbor/plan.pdf"))
        try tree.move("Harbor/plan-new.pdf", to: "Harbor/plan.pdf")
        #expect(await ReplyFiles.recheck(renamedOver, roots: { roots }) == .failure(.changed))
    }

    /// A change of the content, of the size or only of the date, as a save in place gives,
    /// makes it another version than the user ticked.
    @Test func aFileThatChangedIsNotTaken() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let roots = [Self.harbor: [tree.url("Harbor")]]
        let file = try tree.file("Harbor/plan.pdf", "version 1")
        let ticked = try await ReplyFiles.file(at: file, roots: { roots }).get()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" and 2".utf8))
        try handle.close()
        #expect(await ReplyFiles.recheck(ticked, roots: { roots }) == .failure(.changed))

        let again = try await ReplyFiles.file(at: file, roots: { roots }).get()
        try FileManager.default.setAttributes([.modificationDate: again.modified.addingTimeInterval(60)], ofItemAtPath: file.path)
        #expect(await ReplyFiles.recheck(again, roots: { roots }) == .failure(.changed))
    }

    /// The folders come from `roots` at the check, so a folder removed from its project
    /// since the tick refuses its files, also while the index still holds them, and a file
    /// another project still holds goes with that project.
    @Test func theFoldersOfTheProjectsAreReadAtTheCheck() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let current = Roots([Self.harbor: [tree.url("Harbor")], Self.kiln: [tree.url("Harbor/Drawings")]])
        let ticked = try await ReplyFiles.file(at: try tree.file("Harbor/Drawings/plan.pdf"), roots: { current.value }, first: Self.harbor).get()
        #expect(ticked.projects == [Self.harbor, Self.kiln])

        current.value = [Self.harbor: [], Self.kiln: [tree.url("Harbor/Drawings")]]
        let kept = try await ReplyFiles.recheck(ticked, roots: { current.value }).get()
        #expect(kept.projects == [Self.kiln])

        current.value = [:]
        #expect(await ReplyFiles.recheck(ticked, roots: { current.value }) == .failure(.notInAddedFolder))
        #expect(current.reads == 3)
    }

    // MARK: Recipients and sizes

    @Test func theRecipientsOutsideNameEveryoneNoProjectOfTheFileHolds() {
        let harbor = ExplainService.Project(
            id: Self.harbor, name: "Harbor lobby",
            people: [ExplainPrompt.Person(name: "Mei Tan", address: "mei@harbor.example")],
            domains: ["harbor-lights.example"])
        let kiln = ExplainService.Project(id: Self.kiln, name: "Kiln studio", people: [ExplainPrompt.Person(name: "Kai Moss", address: "kai@kiln.example")])
        let recipients = ["Mei Tan <Mei@Harbor.example>", "kai@kiln.example", "KAI@kiln.example", "ana@harbor-lights.example", "pat@new-supplier.example", "not an address"]

        let inHarbor = Self.file(projects: [Self.harbor])
        #expect(ReplyFiles.outside(of: inHarbor, recipients: recipients, projects: [harbor, kiln]) == ["kai@kiln.example", "pat@new-supplier.example", "not an address"])
        let inBoth = Self.file(projects: [Self.harbor, Self.kiln])
        #expect(ReplyFiles.outside(of: inBoth, recipients: recipients, projects: [harbor, kiln]) == ["pat@new-supplier.example", "not an address"])
        // A project that is gone holds no one.
        #expect(ReplyFiles.outside(of: inHarbor, recipients: ["mei@harbor.example"], projects: [kiln]) == ["mei@harbor.example"])
        #expect(ReplyFiles.outside(of: inHarbor, recipients: [], projects: [harbor]) == [])
    }

    @Test func tenFilesAtMostAndALargeTotalAbove20MB() {
        #expect(ReplyFiles.maximum == 10)
        let files = [Self.file(size: 12_000_000), Self.file(size: 8_000_000)]
        #expect(ReplyFiles.total(of: files) == 20_000_000)
        #expect(!ReplyFiles.areLarge(files))
        #expect(ReplyFiles.areLarge(files + [Self.file(size: 1)]))
        #expect(ReplyFiles.total(of: []) == 0)
    }

    private static func file(projects: [UUID] = [harbor], size: Int64 = 1_000) -> ReplyFile {
        ReplyFile(
            url: URL(fileURLWithPath: "/Users/someone/Projects/Harbor/plan-\(size).pdf"),
            projects: projects,
            identity: ReplyFile.Identity(device: 1, fileSystem: 26, number: UInt64(size), size: size, modified: Date(timeIntervalSince1970: 1_760_000_000)))
    }

    /// The folders of the projects as a test changes them, with how often a check read them.
    private final class Roots: Sendable {
        private let state: Mutex<(roots: [UUID: [URL]], reads: Int)>

        init(_ roots: [UUID: [URL]]) {
            state = Mutex((roots, 0))
        }

        var value: [UUID: [URL]] {
            get {
                state.withLock { state in
                    state.reads += 1
                    return state.roots
                }
            }
            set { state.withLock { $0.roots = newValue } }
        }

        var reads: Int {
            state.withLock { $0.reads }
        }
    }

    // MARK: The tree

    private struct Tree {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "orra-reply-files-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func url(_ path: String) -> URL {
            root.appending(path: path)
        }

        /// The path with every link resolved, as the checks give it.
        func real(_ path: String) -> String {
            guard let resolved = realpath(url(path).path, nil) else { return "" }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        @discardableResult
        func folder(_ path: String) throws -> URL {
            try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
            return url(path)
        }

        @discardableResult
        func file(_ path: String, _ text: String = "text") throws -> URL {
            try folder((path as NSString).deletingLastPathComponent)
            try Data(text.utf8).write(to: url(path))
            return url(path)
        }

        func link(_ path: String, to destination: String) throws {
            try FileManager.default.createSymbolicLink(atPath: url(path).path, withDestinationPath: destination)
        }

        /// A rename, which keeps the file's number on the volume.
        func move(_ path: String, to destination: String) throws {
            #expect(rename(url(path).path, url(destination).path) == 0)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
