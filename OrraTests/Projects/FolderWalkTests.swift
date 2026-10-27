import Foundation
import Testing
@testable import Orra

/// What FolderWalk lists, skips and refuses, in a temporary tree with a stand in home
/// folder. Nothing here opens a file.
struct FolderWalkTests {
    /// Every regular file is listed with its kind and folder: documents, images and files
    /// known by name. Hidden files, packages and code folders are only counted.
    @Test func listsEveryFileWithItsKind() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let project = "home/Projects/Alpha"
        for name in ["notes.md", "report.pdf", "Brief.DOCX", "sub/plan.txt", "sub/deeper/terms.rtf", "sub/deeper/specs.odt", "old.doc"] {
            try tree.file("\(project)/\(name)")
        }
        for name in [".draft.md", ".git/config", "node_modules/kit/readme.md", "Viewer.app/Contents/notes.txt",
                     "backup.zip", "budget.xlsx", "deck.pptx", "photo.jpg", "flagged.txt"] {
            try tree.file("\(project)/\(name)")
        }
        #expect(chflags(tree.url("\(project)/flagged.txt").path, UInt32(UF_HIDDEN)) == 0)
        let modified = Date(timeIntervalSince1970: 1_760_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: tree.url("\(project)/notes.md").path)

        // Keynote, Numbers and Pages documents saved as packages are listed by name, and
        // the walk never enters them, whether or not this Mac knows them as packages.
        for name in ["Deck.key/Index.zip", "Budget.numbers/Data/photo.jpg"] {
            try tree.file("\(project)/\(name)")
        }
        let listing = try await tree.walk().list(tree.url(project))
        #expect(names(of: listing) == [
            "Brief.DOCX", "Budget.numbers", "Deck.key", "backup.zip", "budget.xlsx", "deck.pptx", "notes.md", "old.doc", "photo.jpg", "report.pdf",
            "sub/deeper/specs.odt", "sub/deeper/terms.rtf", "sub/plan.txt",
        ])
        #expect(listing.files.map(\.kind) == [
            .text(.docx), .nameOnly(.unsupportedFormat), .nameOnly(.unsupportedFormat), .nameOnly(.archive), .text(.xlsx), .text(.pptx),
            .text(.text), .text(.doc), .image, .text(.pdf), .text(.odt), .text(.rtf), .text(.text),
        ])
        #expect(listing.files.map(\.folder) == ["", "", "", "", "", "", "", "", "", "", "sub/deeper", "sub/deeper", "sub"])
        let notes = try #require(listing.files.first { $0.url.lastPathComponent == "notes.md" })
        #expect(notes.size == 4)
        #expect(notes.modified == modified)
        // Expected skips are only counted.
        #expect(skips(of: listing).isEmpty)
        #expect(listing.skipCounts == [.hidden: 2, .gitFolder: 1, .package: 1, .nodeModules: 1])
        #expect(!listing.reachedLimit && !listing.reachedNameLimit)
        #expect(!listing.wasCancelled)
    }

    @Test func namesAtMostAThousandSkips() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.folder("home/Projects/Alpha")
        for number in 1...(FolderWalk.maximumListedSkips + 5) {
            try tree.link("home/Projects/Alpha/link \(number).md", to: "notes.md")
        }
        let listing = try await tree.walk().list(tree.url("home/Projects/Alpha"))
        #expect(listing.skipped.count == FolderWalk.maximumListedSkips)
        #expect(listing.skipCounts == [.symbolicLink: FolderWalk.maximumListedSkips + 5])
    }

    /// A sparse file has the size of a large one and takes no room. A document or image
    /// over 50 MB is known by its name only, and any file known by name whatever its size.
    @Test func filesOverFiftyMegabytesAreKnownByName() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let project = "home/Projects/Alpha"
        let sizes = [("edge.pdf", FolderWalk.maximumFileSize), ("big.pdf", FolderWalk.maximumFileSize + 1),
                     ("big.jpg", FolderWalk.maximumFileSize + 1), ("film.mp4", 3 * FolderWalk.maximumFileSize)]
        for (name, size) in sizes {
            let handle = try FileHandle(forWritingTo: try tree.file("\(project)/\(name)", ""))
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
        }
        let listing = try await tree.walk().list(tree.url(project))
        #expect(names(of: listing) == ["big.jpg", "big.pdf", "edge.pdf", "film.mp4"])
        #expect(listing.files.map(\.kind) == [.nameOnly(.tooLarge), .nameOnly(.tooLarge), .text(.pdf), .nameOnly(.unsupportedFormat)])
        #expect(skips(of: listing).isEmpty)
    }

    /// A temporary folder holds no dataless file, so the flags come from a stand in. The
    /// walk never looks inside a dataless folder, which would make macOS fetch its list.
    @Test func skipsWhatIsNotOnThisMac() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let project = "home/Projects/Alpha"
        for name in ["kept.md", "evicted.pdf", "older.md", "Evicted Folder/inside.md"] {
            try tree.file("\(project)/\(name)")
        }
        let walk = FolderWalk(
            places: FolderWalk.Places(home: tree.url("home")),
            flags: { path in
                path.hasSuffix("/evicted.pdf") || path.hasSuffix("/Evicted Folder") ? UInt32(SF_DATALESS) : FolderWalk.statFlags(path)
            },
            isDownloaded: { $0.lastPathComponent != "older.md" })
        let listing = try await walk.list(tree.url(project))
        #expect(names(of: listing) == ["kept.md"])
        #expect(skips(of: listing) == ["Evicted Folder": .dataless, "evicted.pdf": .dataless, "older.md": .notDownloaded])
    }

    @Test func neverFollowsASymbolicLink() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let project = "home/Projects/Alpha"
        try tree.file("\(project)/notes.md")
        try tree.file("home/Private/secret.md")
        try tree.link("\(project)/secret.md", to: "../../Private/secret.md")
        try tree.link("\(project)/Private", to: "../../Private")
        try tree.link("\(project)/also notes.md", to: "notes.md")
        try tree.link("home/Projects/Alpha link", to: "Alpha")

        let listing = try await tree.walk().list(tree.url(project))
        #expect(names(of: listing) == ["notes.md"])
        #expect(skips(of: listing) == ["Private": .symbolicLink, "also notes.md": .symbolicLink, "secret.md": .symbolicLink])
        #expect(listing.files.allSatisfy { $0.url.path.hasPrefix(listing.folder.path + "/") })

        // A link the user picks as the folder itself leads to the real folder.
        let throughLink = try await tree.walk().list(tree.url("home/Projects/Alpha link"))
        #expect(throughLink.folder == listing.folder)
        #expect(throughLink.files == listing.files)
    }

    @Test func neverFollowsAFinderAlias() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let project = "home/Projects/Alpha"
        try tree.file("\(project)/notes.md")
        let secret = try tree.file("home/Private/secret.pdf")
        let bookmark = try secret.bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(bookmark, to: tree.url("\(project)/secret.pdf"))
        try URL.writeBookmarkData(bookmark, to: tree.url("\(project)/secret alias"))

        let listing = try await tree.walk().list(tree.url(project))
        #expect(names(of: listing) == ["notes.md"])
        #expect(skips(of: listing) == ["secret alias": .alias, "secret.pdf": .alias])
        #expect(listing.skipCounts == [.alias: 2])
    }

    /// The walk stays off other volumes, such as /System/Volumes/Data, which would lead back
    /// to the home folder, and out of the protected folders and copies of Mail's data.
    @Test func neverEntersAnotherVolumeOrAProtectedFolder() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let project = "home/Projects/Alpha"
        try tree.file("\(project)/notes.md")
        for name in ["Mounted Disk/disk.md", "Shared/shared.md", "Backup/Users/someone/Library/Mail/V10/message.txt",
                     "Backup/Users/someone/Library/Containers/com.apple.mail/Data/message.txt", "Backup/Users/someone/plan.md"] {
            try tree.file("\(project)/\(name)")
        }
        var places = FolderWalk.Places(home: tree.url("home"))
        // A stand in for a protected folder the walk reaches, which only a second path can do.
        places.protectedFolders.append(tree.url("\(project)/Shared"))
        let walk = FolderWalk(places: places, isVolume: { $0.lastPathComponent == "Mounted Disk" })
        let listing = try await walk.list(tree.url(project))
        #expect(names(of: listing) == ["Backup/Users/someone/plan.md", "notes.md"])
        #expect(skips(of: listing) == [
            "Mounted Disk": .volume, "Shared": .protectedFolder, "Backup/Users/someone/Library/Mail": .protectedFolder,
            "Backup/Users/someone/Library/Containers/com.apple.mail": .protectedFolder,
        ])
        // A folder inside a copy of Mail's data is refused, and a volume root.
        for folder in ["Backup/Users/someone/Library/Mail/V10", "Backup/Users/someone/Library/Containers/com.apple.mail/Data"] {
            #expect(await walk.refusal(for: tree.url("\(project)/\(folder)")) == .mailData, "\(folder)")
        }
        #expect(await walk.refusal(for: tree.url("\(project)/Mounted Disk")) == .volumeRoot)
    }

    @Test func stopsWhenItsTaskIsCancelled() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file("home/Projects/Alpha/notes.md")
        let walk = tree.walk()
        let listing = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await walk.list(tree.url("home/Projects/Alpha"))
        }.value
        #expect(listing.wasCancelled)
        #expect(listing.files.isEmpty)
    }

    @Test func refusesMailsDataAndEveryFolderAroundIt() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file("home/Library/Mail/V10/message.txt")
        try tree.file("home/Library/Containers/com.apple.mail/Data/message.txt")
        try tree.file("home/Library/Mobile Documents/com~apple~CloudDocs/Plans/plan.md")
        let walk = tree.walk()
        for folder in ["home/Library", "home/Library/Mail", "home/Library/Mail/V10", "home/Library/Containers",
                       "home/Library/Containers/com.apple.mail/Data", "home/library/MAIL",
                       "home/Library/Mobile Documents/../Mail"] {
            await #expect(throws: FolderWalk.Refusal.mailData, "\(folder)") { try await walk.list(tree.url(folder)) }
        }
        // iCloud Drive lives in ~/Library and can be added.
        let iCloud = try await walk.list(tree.url("home/Library/Mobile Documents/com~apple~CloudDocs/Plans"))
        #expect(names(of: iCloud) == ["plan.md"])
    }

    /// Before Mail ever ran, ~/Library holds no Mail folder, and is still refused.
    @Test func refusesLibraryBeforeMailMadeItsFolder() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.folder("home/Library/Caches")
        #expect(await tree.walk().refusal(for: tree.url("home/Library")) == .mailData)
        #expect(await tree.walk().refusal(for: tree.url("home/Library/Caches")) == nil)
    }

    @Test func refusesTheHomeFolderAndWhatHoldsIt() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        for folder in ["Desktop", "Documents/Taxes", "Downloads"] {
            try tree.folder("home/\(folder)")
        }
        try tree.file("home/notes.md")
        try tree.link("home link", to: "home")
        let walk = tree.walk()
        #expect(await walk.refusal(for: tree.url("home")) == .home)
        #expect(await walk.refusal(for: tree.url("home/Documents/..")) == .home)
        #expect(await walk.refusal(for: tree.url("home link")) == .home)
        #expect(await walk.refusal(for: tree.url("")) == .home)
        await #expect(throws: FolderWalk.Refusal.home) { try await walk.list(tree.url("home")) }
        // Desktop, Documents and Downloads, and folders inside them, can be added.
        for folder in ["home/Desktop", "home/Documents", "home/Documents/Taxes", "home/Downloads"] {
            #expect(await walk.refusal(for: tree.url(folder)) == nil, "\(folder)")
        }
        #expect(await walk.refusal(for: URL(fileURLWithPath: "/")) == .volumeRoot)
        #expect(await walk.refusal(for: tree.url("home/missing")) == .notAFolder)
        #expect(await walk.refusal(for: tree.url("home/notes.md")) == .notAFolder)
    }

    /// Documents past their limit are listed by name. Once the names are full too, the walk
    /// stops.
    @Test func stopsAtItsLimits() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        for number in 1...5 {
            try tree.file("home/Projects/Alpha/note \(number).md")
        }
        let walk = tree.walk()
        let past = try await walk.list(tree.url("home/Projects/Alpha"), documents: 3)
        #expect(past.files.map(\.kind) == [.text(.text), .text(.text), .text(.text), .nameOnly(.overFileLimit), .nameOnly(.overFileLimit)])
        #expect(past.reachedLimit && !past.reachedNameLimit)
        let cut = try await walk.list(tree.url("home/Projects/Alpha"), documents: 3, names: 1)
        #expect(cut.files.count == 4)
        #expect(cut.reachedLimit && cut.reachedNameLimit)
        let whole = try await walk.list(tree.url("home/Projects/Alpha"), documents: 5)
        #expect(whole.files.count == 5)
        #expect(!whole.reachedLimit)
    }

    /// A folder of photos that fills the names never hides the documents after it: the
    /// walk goes on for them. It takes the folders of a folder last name first.
    @Test func documentsAfterAFolderFullOfPhotosAreStillListed() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        for number in 1...8 {
            try tree.file("home/Projects/Alpha/b photos/IMG_\(2040 + number).jpg")
        }
        try tree.file("home/Projects/Alpha/a documents/plan.pdf")
        try tree.file("home/Projects/Alpha/a documents/site.dwg")
        let listing = try await tree.walk().list(tree.url("home/Projects/Alpha"), documents: 10, names: 3)
        #expect(listing.files.filter { $0.kind == .image }.count == 3)
        #expect(names(of: listing).contains("a documents/plan.pdf"))
        #expect(!names(of: listing).contains("a documents/site.dwg"))
        #expect(listing.reachedNameLimit && !listing.reachedLimit)
    }

    // MARK: Helpers

    /// The listed files by their path inside the folder.
    private func names(of listing: FolderWalk.Listing) -> [String] {
        listing.files.map { relative($0.url, in: listing) }
    }

    /// The skipped files and folders by their path inside the folder.
    private func skips(of listing: FolderWalk.Listing) -> [String: FileSkipReason] {
        Dictionary(uniqueKeysWithValues: listing.skipped.map { (relative($0.url, in: listing), $0.reason) })
    }

    private func relative(_ url: URL, in listing: FolderWalk.Listing) -> String {
        String(url.path.dropFirst(listing.folder.path.count + 1))
    }

    /// A temporary folder that holds a stand in home folder.
    private struct Tree {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "orra-folder-walk-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        }

        func url(_ path: String) -> URL {
            path.isEmpty ? root : root.appending(path: path)
        }

        func walk() -> FolderWalk {
            FolderWalk(places: FolderWalk.Places(home: url("home")))
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

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
