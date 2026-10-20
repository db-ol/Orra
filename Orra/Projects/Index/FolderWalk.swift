import Foundation

/// Lists the files of a folder the user added to a project, and nothing outside it.
///
/// - The folder is refused when it is the home folder or holds it, when it is a volume root,
///   and when it is, lies inside or holds Mail's data (~/Library/Mail and
///   ~/Library/Containers/com.apple.mail), or lies inside a copy of it, such as one in a
///   backup. Since a folder that holds the home folder is refused, the walk enters ~/Library,
///   Desktop, Documents and Downloads only when the added folder is one of them or lies
///   inside one. So adding a folder never makes macOS ask about them, and a folder in iCloud
///   Drive (~/Library/Mobile Documents) can still be added.
/// - Places are compared by device and inode as well as by path, so a second path to the
///   same folder, such as one through /System/Volumes/Data, is refused like the first.
/// - The walk never enters another volume, such as /System/Volumes/Data or a disk in
///   /Volumes, the home folder, ~/Library, Desktop, Documents, Downloads or Mail's data
///   reached through a second path, or a copy of Mail's data.
/// - Every path is resolved, symbolic links and `..` included, and a file whose real path
///   leaves the folder is skipped. Symbolic links and Finder aliases are never followed.
/// - Hidden files, packages, .git, node_modules and archives are skipped, and so is every
///   file FileTextExtractor does not read.
/// - Before anything opens a file, files over 50 MB, dataless files and folders (an iCloud or
///   other File Provider item whose data is not on this Mac) and iCloud files that are not
///   downloaded are skipped, so macOS never downloads anything for the index.
nonisolated struct FolderWalk: Sendable {
    /// The largest file the walk lists.
    static let maximumFileSize: Int64 = 50_000_000

    /// The places an added folder is checked against. Tests pass a temporary tree.
    nonisolated struct Places: Sendable {
        var home: URL
        /// ~/Library/Mail and ~/Library/Containers/com.apple.mail.
        var mailData: [URL]
        /// The folders the walk never enters besides Mail's data: the home folder, ~/Library,
        /// Desktop, Documents and Downloads. The walk can reach one of them only through a
        /// second path, since an added folder that holds the home folder is refused.
        var protectedFolders: [URL]

        /// The places of a home folder at `home`, with Mail's data where Mail keeps it.
        init(home: URL) {
            self.home = home
            mailData = [
                home.appending(path: "Library/Mail", directoryHint: .isDirectory),
                home.appending(path: "Library/Containers/com.apple.mail", directoryHint: .isDirectory),
            ]
            protectedFolders = [home] + ["Library", "Desktop", "Documents", "Downloads"].map {
                home.appending(path: $0, directoryHint: .isDirectory)
            }
        }

        /// This Mac's. Orra is not sandboxed, so this is the user's own home folder.
        static var current: Places { Places(home: FileManager.default.homeDirectoryForCurrentUser) }
    }

    /// Why an added folder is refused.
    nonisolated enum Refusal: Error, Sendable, Equatable {
        /// It is missing, is not a folder, or cannot be read.
        case notAFolder
        /// The home folder, or a folder that holds it.
        case home
        /// The top of a disk.
        case volumeRoot
        /// Mail's data, a folder inside it, a folder that holds it, or a folder inside a copy
        /// of it.
        case mailData
    }

    /// A file the walk lists, at its real path.
    nonisolated struct File: Sendable, Equatable {
        var url: URL
        var format: FileTextExtractor.Format
        var size: Int64
        var modified: Date
    }

    /// A file or folder the walk skips. The walk never looks inside a skipped folder.
    nonisolated struct Skip: Sendable, Equatable {
        var url: URL
        var reason: FileSkipReason
    }

    nonisolated struct Listing: Sendable, Equatable {
        /// The added folder's real path.
        var folder: URL
        /// Sorted by path.
        var files: [File] = []
        /// The skipped files and folders a person may want to hear about, sorted by path, at
        /// most `FolderWalk.maximumListedSkips` of them. The reasons in
        /// `FolderWalk.countedSkips` are only counted.
        var skipped: [Skip] = []
        /// Every skipped file and folder, listed or not, counted by reason.
        var skipCounts: [FileSkipReason: Int] = [:]
        /// Whether the walk stopped at its limit of files.
        var reachedLimit = false
        /// Whether the walk stopped because its task was cancelled. The listing holds what
        /// the walk found until then.
        var wasCancelled = false
    }

    /// The most skipped files and folders a listing names.
    static let maximumListedSkips = 1_000
    /// Skips a listing only counts, since a folder may hold many and they are expected.
    static let countedSkips: Set<FileSkipReason> = [.hidden, .package, .gitFolder, .nodeModules, .archive, .unsupportedFormat]

    let places: Places
    let maximumFileSize: Int64
    /// The stat flags of a path, such as SF_DATALESS. Tests pass a stand in, since a
    /// temporary folder holds no dataless file.
    let flags: @Sendable (String) -> UInt32?
    /// Whether a file is on this Mac in its newest version. Tests pass a stand in.
    let isDownloaded: @Sendable (URL) -> Bool
    /// Whether a folder is the root of a volume. Tests pass a stand in, since a temporary
    /// folder holds no volume.
    let isVolume: @Sendable (URL) -> Bool

    init(
        places: Places = .current,
        maximumFileSize: Int64 = FolderWalk.maximumFileSize,
        flags: @escaping @Sendable (String) -> UInt32? = FolderWalk.statFlags,
        isDownloaded: @escaping @Sendable (URL) -> Bool = FolderWalk.isDownloaded,
        isVolume: @escaping @Sendable (URL) -> Bool = FolderWalk.isVolume
    ) {
        self.places = places
        self.maximumFileSize = maximumFileSize
        self.flags = flags
        self.isDownloaded = isDownloaded
        self.isVolume = isVolume
    }

    /// Why `folder` cannot be added, or nil when it can.
    @concurrent
    func refusal(for folder: URL) async -> Refusal? {
        if case .failure(let refusal) = resolve(folder) { return refusal }
        return nil
    }

    /// The files of `folder` and its folders, at most `limit` of them. Off the main actor,
    /// since a large folder takes a while and the keyboard tap runs on the main thread. The
    /// walk checks for cancellation once a folder.
    @concurrent
    func list(_ folder: URL, limit: Int = .max) async throws(Refusal) -> Listing {
        switch resolve(folder) {
        case .success(let root): return walk(from: root, limit: limit)
        case .failure(let refusal): throw refusal
        }
    }

    // MARK: The added folder

    /// The real path of `folder`, or why it is refused.
    private func resolve(_ folder: URL) -> Result<String, Refusal> {
        guard let path = Self.realPath(folder.path) else { return .failure(.notAFolder) }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .failure(.notAFolder) }
        if isVolume(URL(fileURLWithPath: path, isDirectory: true)) { return .failure(.volumeRoot) }
        if Self.liesInMailDataByName(path) { return .failure(.mailData) }
        let added = Self.placeAndAbove(path)
        if Self.placeAndAbove(Self.canonical(places.home.path)).contains(where: { $0.matches(added[0]) }) {
            return .failure(.home)
        }
        for mailData in places.mailData {
            let mail = Self.placeAndAbove(Self.canonical(mailData.path))
            if added.contains(where: { $0.matches(mail[0]) }) || mail.contains(where: { $0.matches(added[0]) }) {
                return .failure(.mailData)
            }
        }
        return .success(path)
    }

    /// A folder by its path and, when it exists, by its device and inode.
    private struct Place {
        var path: String
        var device: dev_t?
        var inode: ino_t?

        init(_ path: String) {
            self.path = path
            var info = stat()
            if lstat(path, &info) == 0 {
                device = info.st_dev
                inode = info.st_ino
            }
        }

        init(_ path: String, info: stat) {
            self.path = path
            device = info.st_dev
            inode = info.st_ino
        }

        /// The same folder. Paths are compared without case, which refuses a little more
        /// on a volume that tells case apart.
        func matches(_ other: Place) -> Bool {
            if let device, let inode, let otherDevice = other.device, let otherInode = other.inode {
                return device == otherDevice && inode == otherInode
            }
            return path.lowercased() == other.path.lowercased()
        }
    }

    /// The place at `path` and every folder above it, up to the root.
    private static func placeAndAbove(_ path: String) -> [Place] {
        var places = [Place(path)]
        var current = path
        while current != "/" && !current.isEmpty {
            current = (current as NSString).deletingLastPathComponent
            places.append(Place(current.isEmpty ? "/" : current))
        }
        return places
    }

    /// Whether `path` is or lies inside a folder whose path ends in Library/Mail or
    /// Library/Containers/com.apple.mail, wherever it is, so a copy in a backup counts too.
    private static func liesInMailDataByName(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/")
        return parts.indices.contains { index in
            parts[index...].starts(with: ["library", "mail"]) || parts[index...].starts(with: ["library", "containers", "com.apple.mail"])
        }
    }

    /// Whether `path` ends in Library/Mail or Library/Containers/com.apple.mail, wherever it
    /// is.
    private static func isMailDataByName(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/")
        return parts.suffix(2).elementsEqual(["library", "mail"]) || parts.suffix(3).elementsEqual(["library", "containers", "com.apple.mail"])
    }

    /// The real path of `path`, or for a path that does not exist, the real path of the
    /// nearest folder above it that does, with the rest added.
    private static func canonical(_ path: String) -> String {
        let path = (path as NSString).standardizingPath
        if let real = realPath(path) { return real }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (canonical(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    // MARK: The walk

    private enum Examined {
        case folder
        case file(File)
        case skip(FileSkipReason, isFolder: Bool)
    }

    private func walk(from root: String, limit: Int) -> Listing {
        var listing = Listing(folder: URL(fileURLWithPath: root, isDirectory: true))
        func skip(_ url: URL, _ reason: FileSkipReason) {
            listing.skipCounts[reason, default: 0] += 1
            if !Self.countedSkips.contains(reason), listing.skipped.count < Self.maximumListedSkips {
                listing.skipped.append(Skip(url: url, reason: reason))
            }
        }
        if let rootFlags = flags(root), rootFlags & UInt32(SF_DATALESS) != 0 {
            skip(listing.folder, .dataless)
            return listing
        }
        let protected = (places.protectedFolders + places.mailData).map { Place(Self.canonical($0.path)) }
        var folders = [root]
        walking: while let folder = folders.popLast() {
            if Task.isCancelled {
                listing.wasCancelled = true
                break
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                skip(URL(fileURLWithPath: folder, isDirectory: true), .noAccess)
                continue
            }
            for name in names.sorted() {
                let path = folder + "/" + name
                switch examine(path, inside: root, protected: protected) {
                case .folder:
                    folders.append(path)
                case .file(let file):
                    guard listing.files.count < limit else {
                        listing.reachedLimit = true
                        break walking
                    }
                    listing.files.append(file)
                case .skip(let reason, let isFolder):
                    skip(URL(fileURLWithPath: path, isDirectory: isFolder), reason)
                }
            }
        }
        listing.files.sort { $0.url.path < $1.url.path }
        listing.skipped.sort { $0.url.path < $1.url.path }
        return listing
    }

    /// What the walk does with `path`, read without following a link and without opening
    /// a file.
    private func examine(_ path: String, inside root: String, protected: [Place]) -> Examined {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .skip(.noAccess, isFolder: false) }
        let type = info.st_mode & S_IFMT
        let isFolder = type == S_IFDIR
        let name = (path as NSString).lastPathComponent
        if isFolder && name == ".git" { return .skip(.gitFolder, isFolder: true) }
        if isFolder && name == "node_modules" { return .skip(.nodeModules, isFolder: true) }
        if name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 { return .skip(.hidden, isFolder: isFolder) }
        if type == S_IFLNK { return .skip(.symbolicLink, isFolder: false) }
        let url = URL(fileURLWithPath: path, isDirectory: isFolder)
        let isDataless = (flags(path) ?? info.st_flags) & UInt32(SF_DATALESS) != 0
        if isFolder {
            if isDataless { return .skip(.dataless, isFolder: true) }
            let place = Place(path, info: info)
            if Self.isMailDataByName(path) || protected.contains(where: { $0.matches(place) }) {
                return .skip(.protectedFolder, isFolder: true)
            }
            if isVolume(url) { return .skip(.volume, isFolder: true) }
            if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return .skip(.package, isFolder: true) }
            return .folder
        }
        guard type == S_IFREG else { return .skip(.unsupportedFormat, isFolder: false) }
        // The extension first, so a folder of photos costs no alias lookups.
        let format: FileTextExtractor.Format
        switch FileTextExtractor.format(ofExtension: url.pathExtension) {
        case .success(let found): format = found
        case .failure(let reason): return .skip(reason, isFolder: false)
        }
        if (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true { return .skip(.alias, isFolder: false) }
        if Int64(info.st_size) > maximumFileSize { return .skip(.tooLarge, isFolder: false) }
        if isDataless { return .skip(.dataless, isFolder: false) }
        if !isDownloaded(url) { return .skip(.notDownloaded, isFolder: false) }
        guard let real = Self.realPath(path), real.hasPrefix(root + "/") else { return .skip(.outsideFolder, isFolder: false) }
        return .file(File(url: URL(fileURLWithPath: real), format: format, size: Int64(info.st_size), modified: Self.date(of: info)))
    }

    // MARK: Helpers

    /// The stat flags of `path` without following a link, nil when it cannot be read.
    static func statFlags(_ path: String) -> UInt32? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_flags : nil
    }

    /// Whether `url` is the root of a volume.
    static func isVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    /// Whether `url` is on this Mac in its newest version. Always true outside iCloud.
    static func isDownloaded(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    static func date(of info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// `path` with every symbolic link and `..` resolved, nil when it does not exist.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
