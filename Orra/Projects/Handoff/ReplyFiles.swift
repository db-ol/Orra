import Foundation

/// A file the user ticked for a reply, as it was when ticked: its real path, the projects
/// whose folders hold it, and what makes it this file. In memory only, never saved or
/// logged.
nonisolated struct ReplyFile: Sendable, Equatable, Identifiable {
    /// What makes a file the same file: its resource identifier, the volume and the file's
    /// number on it, which URL's fileResourceIdentifier compares too, with the date it was
    /// made, its size and the date it changed. A rename on the same volume keeps them all. A
    /// new file at the path, a file saved anew in place of the old one, and a change of its
    /// content do not. APFS never gives a file's number to another file, and the date it
    /// was made tells a newer file apart on a volume that does. A process that can write the
    /// user's files could still change one and set its dates back, which no check of a
    /// file's state can tell.
    nonisolated struct Identity: Sendable, Equatable {
        /// The volume, as lstat gives it.
        var device: Int32
        /// The type number of the volume's file system, which finds the file by its number.
        var fileSystem: Int32
        /// The file's number on the volume.
        var number: UInt64
        var made: Date
        var size: Int64
        var modified: Date
    }

    /// Its real path: a file shows once in the reply's files, by where it really is.
    var id: String { url.path }
    /// Its real path, every symbolic link and `..` resolved.
    var url: URL
    /// The projects whose folders hold it, the email's project first.
    var projects: [UUID]
    let identity: Identity

    var size: Int64 { identity.size }
    var modified: Date { identity.modified }
}

/// Why a file cannot go into a reply. None names the file.
nonisolated enum ReplyFileProblem: Error, Sendable, Equatable {
    /// No folder a project holds now has it, as after its folder left the project, or it
    /// was never in one.
    case notInAddedFolder
    /// The file is neither at its path nor anywhere else on its volume, as after a delete or
    /// a move to another disk.
    case moved
    /// Its path, or the place it moved to, holds another file or another content than the
    /// user ticked: another file took its place, it was saved anew, or it changed.
    case changed
    /// Its content is not on this Mac, as for an iCloud file that is not downloaded.
    case notDownloaded
    /// A folder, such as a package some apps save as a document. A reply takes single files.
    case package
}

/// The files of a reply: how many and how large they may be, which recipients a file
/// reaches outside its projects, and the checks that keep a reply to files the user ticked
/// in the folders the user added to a project.
///
/// A ticked file is known by its identity, never by a row of the index, whose ids SQLite
/// may give to another file once a row goes. `recheck(_:roots:)` checks it again right
/// before it goes to Mail: still the same file, still in a folder that a project holds at
/// that moment, as `roots` gives the folders then, and still on this Mac. A file renamed or
/// moved on its volume is found again by its number and taken from its new place only when
/// it is still the same file in such a folder.
///
/// The checks read the disk on a thread of their own, as ProjectList's resolve does: a file
/// on a share that hangs can hold that thread for long, and a thread that Swift tasks share
/// would hold up their other work, such as the dictation's. They read metadata only, never
/// a file's content, and log nothing.
nonisolated enum ReplyFiles {
    typealias Identity = ReplyFile.Identity

    /// The most files Orra attaches to one reply.
    static let maximum = 10
    /// The total size above which many mail servers refuse a message, in bytes.
    static let largeTotal: Int64 = 20_000_000

    /// The file at a path the user ticked or added, when it may go into a reply: a regular
    /// file on this Mac, not a folder or a package, inside a folder that `roots` gives for a
    /// project. `roots` gives the folders of every project as they are now, by project.
    /// `first` is the email's project, which comes first among the file's projects.
    static func file(
        at url: URL,
        roots: @Sendable () async -> [UUID: [URL]],
        first: UUID? = nil,
        isDownloaded: @escaping @Sendable (URL) -> Bool = FolderWalk.isDownloaded
    ) async -> Result<ReplyFile, ReplyFileProblem> {
        let roots = await roots()
        return await onItsOwnThread {
            guard url.isFileURL, let real = realPath(url.path) else { return .failure(.moved) }
            return check(real, roots: roots, order: first.map { [$0] } ?? [], isDownloaded: isDownloaded) { $0 }
        }
    }

    /// A ticked file checked again right before it goes to Mail, with the folders that
    /// `roots` gives then. Gives the file as it is now, at its new place after a rename, with
    /// the projects that hold it now, the ones it had first. A file whose identity no longer
    /// matches is never taken, whatever its name.
    static func recheck(
        _ file: ReplyFile,
        roots: @Sendable () async -> [UUID: [URL]],
        isDownloaded: @escaping @Sendable (URL) -> Bool = FolderWalk.isDownloaded
    ) async -> Result<ReplyFile, ReplyFileProblem> {
        let roots = await roots()
        return await onItsOwnThread {
            recheckNow(file, roots: roots, isDownloaded: isDownloaded)
        }
    }

    /// The recipients a reply reaches that none of the file's projects holds, as people of
    /// the project or at its domains, each once and as ProjectsAddress.normalized gives it.
    /// A file in the folders of two projects counts as inside for anyone of either. With no
    /// project of the file among `projects`, every recipient is outside.
    static func outside(of file: ReplyFile, recipients: [String], projects: [ExplainService.Project]) -> [String] {
        let holding = projects.filter { file.projects.contains($0.id) }
        var seen: Set<String> = []
        var outside: [String] = []
        for recipient in recipients {
            let address = ProjectsAddress.normalized(recipient) ?? recipient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !address.isEmpty, seen.insert(address).inserted else { continue }
            if !holding.contains(where: { ExplainService.isInProject(address, $0) }) {
                outside.append(address)
            }
        }
        return outside
    }

    /// The size of the files together, in bytes.
    static func total(of files: [ReplyFile]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// Whether the files together are larger than many mail servers take.
    static func areLarge(_ files: [ReplyFile]) -> Bool {
        total(of: files) > largeTotal
    }

    // MARK: Checks

    private static func recheckNow(_ file: ReplyFile, roots: [UUID: [URL]], isDownloaded: @Sendable (URL) -> Bool) -> Result<ReplyFile, ReplyFileProblem> {
        let identity = file.identity
        let same = { (found: Identity) in found.device == identity.device && found.number == identity.number }
        // The file at its path, unless a link now leads there.
        if samePath(realPath(file.url.path), file.url.path), let found = self.identity(of: file.url.path) {
            if same(found) {
                return check(file.url.path, roots: roots, order: file.projects, isDownloaded: isDownloaded) { _ in identity }
            }
        }
        // Moved or renamed on its volume: the file with the same number, wherever it is now.
        guard let moved = path(of: identity), let real = realPath(moved), let found = self.identity(of: real), same(found) else {
            return .failure(realPath(file.url.path) == nil ? .moved : .changed)
        }
        return check(real, roots: roots, order: file.projects, isDownloaded: isDownloaded) { _ in identity }
    }

    /// The checks of a file at a real path, and the file with its identity. `expected` gives
    /// the identity the file must have, from the one found, so a recheck refuses a file that
    /// changed.
    private static func check(
        _ real: String,
        roots: [UUID: [URL]],
        order: [UUID],
        isDownloaded: @Sendable (URL) -> Bool,
        expected: (Identity) -> Identity
    ) -> Result<ReplyFile, ReplyFileProblem> {
        var info = stat()
        guard lstat(real, &info) == 0 else { return .failure(.moved) }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: return .failure(.package)
        default: return .failure(.notInAddedFolder)
        }
        guard let found = identity(of: real, info: info) else { return .failure(.moved) }
        guard found == expected(found) else { return .failure(.changed) }
        let url = URL(fileURLWithPath: real, isDirectory: false)
        guard info.st_flags & UInt32(SF_DATALESS) == 0, isDownloaded(url) else { return .failure(.notDownloaded) }
        let projects = holding(real, roots: roots, order: order)
        guard !projects.isEmpty else { return .failure(.notInAddedFolder) }
        // A folder moved or a file replaced while the checks ran shows now: the path must
        // still be real and still hold the same file.
        guard samePath(realPath(real), real), identity(of: real) == found else { return .failure(.changed) }
        return .success(ReplyFile(url: url, projects: projects, identity: found))
    }

    /// The projects whose folders hold the real path: those of `order` first, in its order,
    /// then the others by their ids, so the result never depends on the order of a
    /// dictionary.
    private static func holding(_ real: String, roots: [UUID: [URL]], order: [UUID]) -> [UUID] {
        let inside = Set(roots.compactMap { project, folders in
            folders.contains { folder in
                realPath(folder.path).map { isInside(real, root: $0) } ?? false
            } ? project : nil
        })
        let first = order.filter(inside.contains)
        let rest = inside.subtracting(first).sorted { $0.uuidString < $1.uuidString }
        return first + rest
    }

    /// The identity of what is at a path, read without following a link.
    private static func identity(of path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return identity(of: path, info: info)
    }

    private static func identity(of path: String, info: stat) -> Identity? {
        var volume = statfs()
        guard statfs(path, &volume) == 0 else { return nil }
        return Identity(
            device: info.st_dev,
            fileSystem: volume.f_fsid.val.1,
            number: UInt64(info.st_ino),
            made: Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec) + TimeInterval(info.st_birthtimespec.tv_nsec) / 1_000_000_000),
            size: Int64(info.st_size),
            modified: FolderWalk.date(of: info)
        )
    }

    /// Where the file with this identity is now on its volume, by its number, nil when the
    /// volume has no file with that number or cannot say.
    private static func path(of identity: Identity) -> String? {
        var volume = fsid_t(val: (identity.device, identity.fileSystem))
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fsgetpath(&buffer, buffer.count, &volume, identity.number) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Whether a real path lies inside a real folder, compared by their bytes, so a folder
    /// whose name starts like another's, or differs from it only in how an accent is
    /// written, is another folder.
    static func isInside(_ path: String, root: String) -> Bool {
        let folder = root.hasSuffix("/") ? root : root + "/"
        return Array(path.utf8).starts(with: Array(folder.utf8))
    }

    /// Whether two paths are the same bytes. Swift compares strings by their canonical
    /// form, so two names that differ only in how an accent is written count as equal, while
    /// a file system that keeps both forms holds two folders.
    private static func samePath(_ first: String?, _ second: String) -> Bool {
        first.map { Array($0.utf8) == Array(second.utf8) } ?? false
    }

    /// `path` with every symbolic link and `..` resolved, nil when it does not exist.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func onItsOwnThread<Answer: Sendable>(_ work: @escaping @Sendable () -> Answer) async -> Answer {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: work())
            }
            thread.name = "Orra reply files"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
