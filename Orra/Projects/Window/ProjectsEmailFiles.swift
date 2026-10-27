import Foundation

/// The project files of an explanation, for the email view: where each file is in the
/// folders of its project now. It reads no file. The folders come from
/// ProjectsRuntime.folderRoots(of:), and the files from the saved explanation.
nonisolated enum ProjectsEmailFiles {
    /// A project's folders as they are now, see ProjectsRuntime.folderRoots(of:).
    nonisolated struct Roots: Sendable, Equatable {
        /// The real paths of the folders that are there, in the project's order, since the
        /// index keeps every file at its real path, see FolderWalk.
        var folders: [URL] = []
        /// Where the folders whose bookmarks find nothing now were, by the path each
        /// bookmark keeps, such as a folder on a disk that is not connected.
        var unavailable: [URL] = []
    }

    /// Where a file is, by the folders of its project now.
    nonisolated enum Place: Sendable, Equatable {
        /// In one of the project's folders: that folder's name and the folders inside it down
        /// to the file. When the folders nest, the deepest one that holds the file counts.
        case inFolder(name: String, path: [String])
        /// In a folder of the project that is not available now, with the same parts.
        case unavailable(name: String, path: [String])
        /// In none of the project's folders, such as after its folder left the project: the
        /// folder the file is in.
        case outside(URL)
    }

    /// Where `file` is in `roots`. Names are compared without case, as FolderWalk compares
    /// places, and a folder holds only what lies inside it, so /A/Lobby does not hold
    /// /A/Lobby old/plan.pdf.
    static func place(of file: URL, in roots: Roots) -> Place {
        if let found = deepest(holding: file, in: roots.folders) {
            return .inFolder(name: found.folder.lastPathComponent, path: found.path)
        }
        if let found = deepest(holding: file, in: roots.unavailable) {
            return .unavailable(name: found.folder.lastPathComponent, path: found.path)
        }
        return .outside(file.deletingLastPathComponent())
    }

    /// The deepest of `folders` that holds `file`, with the folders between them. The paths
    /// are compared as they are, both real paths, never standardized, since standardizing
    /// takes /private off the path of a folder that exists, such as /private/var, and not
    /// off that of a file that no longer does.
    private static func deepest(holding file: URL, in folders: [URL]) -> (folder: URL, path: [String])? {
        let parts = file.pathComponents
        var found: (folder: URL, path: [String])?
        var depth = 0
        for folder in folders {
            let root = folder.pathComponents
            guard root.count > depth, root.count < parts.count,
                  zip(root, parts).allSatisfy({ $0.lowercased() == $1.lowercased() }) else { continue }
            found = (folder, Array(parts[root.count..<(parts.count - 1)]))
            depth = root.count
        }
        return found
    }
}
