import Foundation

/// A file of the project folders that may be one an email asks for, as the index lists it.
/// In memory only, never saved or logged.
nonisolated struct RequestedFile: Sendable, Equatable, Identifiable {
    /// Its real path, as the index keeps it, so a file shows once.
    var id: String { url.path }
    var url: URL
    /// The project whose folders hold it, the email's when they do.
    var project: UUID
    /// When it changed, as the index last listed it.
    var modified: Date
    /// Whether another file found for the same request replaced it, see FileVersions.
    var isOlderVersion = false
}

/// Finds the files of the project folders that a request for files may mean, from the
/// index only, see FileRequests for the requests. For each kind of document the request
/// names, it fuses three lists by reciprocal rank fusion with ChunkSearch's constant:
/// - the files whose name or folder holds a word for that kind in one of four languages, or
///   a file name the request gives, each as a phrase, see FileNameSearch, so a drawing or an
///   image without text is found by its name
/// - the files whose name or folder holds the words of what the request asks for
/// - the files whose text holds a word for that kind, see ChunkSearch, so a quote saved as
///   Q3-numbers.xlsx is found by its text
///
/// A file counts for a kind only when its name or its text holds a word for that kind or a
/// file name the request gives. For a kind that is a kind of file, such as a photo or a
/// drawing, see DocumentKind.fileTypes, a file of another type counts only by its name, and
/// the files of the kind's types come first among a project's files, so the photos of the
/// shop come before a brief whose text talks of photos. A request that names no kind but
/// has words of its own, such as "the lighting file", counts the files whose name or text
/// holds them. The email's project comes first, and files of other projects fill only the
/// places its own files leave. A Keynote, Numbers or Pages document saved as a package is
/// left out, since a reply takes single files. A file a newer file of the same document
/// replaced, by their names, is marked older and follows the newer one. At most `perKind`
/// files a kind and `perRequest` a request, each file once.
///
/// It never reads a file's content. It reads the index, and the metadata of a file that may
/// be a package, on a thread of its own, as ReplyFiles does.
nonisolated enum RequestedFiles {
    /// The most files a kind of document gets.
    static let perKind = 3
    /// The most files a request gets.
    static let perRequest = 6
    /// The files each name list gives to the fusion.
    static let nameLimit = 20
    /// The chunks the text list reads.
    static let chunkLimit = 30

    /// The files for a request, best first. `scope` is nil for the folders of every project,
    /// or the projects whose folders may be searched, such as the email's own alone.
    @concurrent
    static func find(
        _ request: FileRequest,
        emailProject: UUID?,
        scope: [UUID]?,
        names: FileNameSearch,
        chunks: ChunkSearch,
        limit: Int = perKind,
        isPackage: @escaping @Sendable ([URL]) async -> Set<URL> = packages
    ) async throws -> [RequestedFile] {
        guard scope?.isEmpty != true, limit > 0 else { return [] }
        let asked = FileRequests.searchTerms(for: request)
        let kinds = request.documentKinds.filter { !$0.isGeneric }
        // One group for each kind the request names, or one without a kind for a request
        // by its own words or a file name.
        let groups: [(terms: [String], types: Set<String>?)] = kinds.isEmpty ? [([], nil)] : kinds.map { (Self.terms(of: $0), $0.fileTypes) }
        guard !asked.words.isEmpty || !kinds.isEmpty || !asked.fileNames.isEmpty else { return [] }
        var found: [RequestedFile] = []
        for (terms, types) in groups {
            try Task.checkCancellation()
            var candidates = try await group(
                words: asked.words, terms: terms, types: types, fileNames: asked.fileNames, emailProject: emailProject, scope: scope,
                names: names, chunks: chunks)
            candidates.removeAll { candidate in found.contains { $0.id == candidate.id } }
            let packages = await isPackage(candidates.map(\.url).filter { FolderWalk.documentPackages.contains($0.pathExtension.lowercased()) })
            candidates.removeAll { packages.contains($0.url) }
            found += Array(candidates.prefix(limit))
            if found.count >= perRequest { break }
        }
        return Array(found.prefix(perRequest))
    }

    /// The words for a kind in the order ChunkSearch reads its first terms in: the first
    /// word of each language, then the second of each, and so on, so each language's most
    /// common words come first.
    static func terms(of kind: DocumentKind) -> [String] {
        let lists = [kind.terms.english, kind.terms.chinese, kind.terms.japanese, kind.terms.spanish]
        var terms: [String] = []
        for index in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where index < list.count && !terms.contains(list[index]) {
                terms.append(list[index])
            }
        }
        return terms
    }

    /// The files of one kind, or of a request without a kind, best first, the email's
    /// project's before the others, and within each the files of the kind's `types` first,
    /// a replaced file after the file that replaced it.
    private static func group(
        words: String, terms: [String], types: Set<String>?, fileNames: [String], emailProject: UUID?, scope: [UUID]?,
        names: FileNameSearch, chunks: ChunkSearch
    ) async throws -> [RequestedFile] {
        let asked = terms + fileNames
        var eligible: Set<Key> = []
        var namedByTerms: Set<Key> = []
        var files: [Key: RequestedFile] = [:]
        func take(_ hit: FileNameSearch.Hit) -> Key {
            let key = Key(path: hit.url.path, project: hit.project)
            if files[key] == nil {
                files[key] = RequestedFile(url: hit.url, project: hit.project, modified: hit.modified)
            }
            return key
        }
        var fused: [[Key]] = []
        if !asked.isEmpty {
            let named = try await names.search("", terms: asked, in: scope, limit: nameLimit).map(take)
            fused.append(named)
            eligible.formUnion(named)
            namedByTerms.formUnion(named)
        }
        if !words.isEmpty {
            let named = try await names.search(words, in: scope, limit: nameLimit).map(take)
            fused.append(named)
            if asked.isEmpty {
                eligible.formUnion(named)
            }
        }
        // The text: chunks a word for the kind matches, or for a request without a kind,
        // chunks its own words match. Each file counts once, at its best chunk.
        let query = ChunkSearch.Query(text: words, terms: terms, projects: scope, termsOnly: !terms.isEmpty, limit: chunkLimit)
        if !terms.isEmpty || !words.isEmpty {
            var seen: Set<Key> = []
            var texts: [Key] = []
            for hit in try await chunks.search(query) {
                let key = Key(path: hit.file.path, project: hit.project)
                guard seen.insert(key).inserted else { continue }
                if files[key] == nil {
                    files[key] = RequestedFile(url: hit.file, project: hit.project, modified: hit.modified)
                }
                texts.append(key)
            }
            fused.append(texts)
            eligible.formUnion(texts)
        }
        // A file of another type than the kind's counts only by its name.
        func fits(_ key: Key) -> Bool {
            types?.contains(URL(fileURLWithPath: key.path).pathExtension.lowercased()) ?? true
        }
        eligible = eligible.filter { fits($0) || namedByTerms.contains($0) }
        var scores: [Key: Double] = [:]
        for list in fused {
            for (rank, key) in list.enumerated() where eligible.contains(key) {
                scores[key, default: 0] += 1 / (ChunkSearch.fusionOffset + Double(rank))
            }
        }
        // Each path once, by its email's project when that holds it, and best first.
        var best: [String: (key: Key, score: Double)] = [:]
        for (key, score) in scores {
            let isOwn = key.project == emailProject
            if let kept = best[key.path], kept.key.project == emailProject || (!isOwn && kept.score >= score) {
                continue
            }
            best[key.path] = (key, score)
        }
        let ranked = best.values.sorted { first, second in
            let firstOwn = first.key.project == emailProject, secondOwn = second.key.project == emailProject
            if firstOwn != secondOwn { return firstOwn }
            let firstFits = fits(first.key), secondFits = fits(second.key)
            if firstFits != secondFits { return firstFits }
            if first.score != second.score { return first.score > second.score }
            return first.key.path < second.key.path
        }
        let ordered = ranked.compactMap { files[$0.key] }
        return olderAfterNewer(ordered)
    }

    /// The files with each one a newer file of the list replaced, by their names, marked
    /// older and moved right after the file that replaced it, see FileVersions.
    static func olderAfterNewer(_ files: [RequestedFile]) -> [RequestedFile] {
        let versions = FileVersions(files.map { FileVersions.File(url: $0.url, modified: $0.modified) })
        var marked = files
        for index in marked.indices where versions.replaced[marked[index].url] != nil {
            marked[index].isOlderVersion = true
        }
        var ordered: [RequestedFile] = []
        var placed: Set<String> = []
        func place(_ file: RequestedFile) {
            guard placed.insert(file.id).inserted else { return }
            ordered.append(file)
            // The files it replaced follow it, in the order of the list.
            for older in marked where versions.replaced[older.url] == file.url {
                place(older)
            }
        }
        for file in marked {
            // A replaced file whose newer file is in the list goes with that file.
            if let newer = versions.replaced[file.url], marked.contains(where: { $0.url == newer }) {
                continue
            }
            place(file)
        }
        for file in marked {
            place(file)
        }
        return ordered
    }

    /// A file in the index: its path and the project whose folders list it. A file in the
    /// folders of two projects has a row in each.
    private nonisolated struct Key: Hashable, Sendable {
        var path: String
        var project: UUID
    }

    /// Which of the files are folders, such as a Keynote, Numbers or Pages document saved as
    /// a package, read with lstat on a thread of its own, since a file on a share that hangs
    /// would hold a thread that Swift tasks share.
    static func packages(_ files: [URL]) async -> Set<URL> {
        guard !files.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                var folders: Set<URL> = []
                for file in files {
                    var info = stat()
                    if lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                        folders.insert(file)
                    }
                }
                continuation.resume(returning: folders)
            }
            thread.name = "Orra requested files"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
