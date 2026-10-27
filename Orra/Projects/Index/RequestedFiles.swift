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
/// places its own files leave, each only when a word of the request besides its words for
/// the kind of document, such as a name, a place, a product or a number, is in the file's
/// name, its folder, its text or its project's name, see `namingWords(of:people:ownName:)`.
/// So a request for all the quotes and contracts of "your folder" stays in the email's
/// project. A Keynote, Numbers or Pages document saved as a package is left out, since a
/// reply takes single files. A file a newer file of the same document
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

    /// Which lists a search fuses: the names, the text, or both, as the app searches. The
    /// opt in FileRequestEvaluationTests compares them.
    nonisolated struct Lists: OptionSet, Sendable {
        let rawValue: Int
        static let names = Lists(rawValue: 1)
        static let text = Lists(rawValue: 2)
        static let both: Lists = [.names, .text]
    }

    /// The files for a request, best first. `scope` is nil for the folders of every project,
    /// or the projects whose folders may be searched, such as the email's own alone.
    /// `people` are the names of the email's people and `ownName` the user's, which bring in
    /// no file of another project, and `projectNames` the names of the projects, which a
    /// request may name. `searchTerms`, such as the terms the cleanup model gave for the
    /// email, join the words of the text list of each kind, so they rank its chunks while a
    /// chunk still counts only by a word for the kind. The app passes none, see
    /// FileRequestEvaluationTests.
    @concurrent
    static func find(
        _ request: FileRequest,
        emailProject: UUID?,
        scope: [UUID]?,
        names: FileNameSearch,
        chunks: ChunkSearch,
        people: [String] = [],
        ownName: String = "",
        projectNames: [UUID: String] = [:],
        limit: Int = perKind,
        lists: Lists = .both,
        searchTerms: [String] = [],
        isPackage: @escaping @Sendable ([URL]) async -> Set<URL> = packages
    ) async throws -> [RequestedFile] {
        guard scope?.isEmpty != true, limit > 0 else { return [] }
        let asked = FileRequests.searchTerms(for: request)
        let kinds = request.documentKinds.filter { !$0.isGeneric }
        // One group for each kind the request names, or one without a kind for a request
        // by its own words or a file name.
        let groups: [(terms: [String], types: Set<String>?)] = kinds.isEmpty ? [([], nil)] : kinds.map { (Self.terms(of: $0), $0.fileTypes) }
        guard !asked.words.isEmpty || !kinds.isEmpty || !asked.fileNames.isEmpty else { return [] }
        let naming = namingWords(of: request, people: people, ownName: ownName)
        var found: [RequestedFile] = []
        for (terms, types) in groups {
            try Task.checkCancellation()
            var candidates = try await group(
                words: asked.words, terms: terms, types: types, fileNames: asked.fileNames, emailProject: emailProject, scope: scope,
                names: names, chunks: chunks, lists: lists, searchTerms: searchTerms)
            candidates.removeAll { candidate in found.contains { $0.id == candidate.id } }
            candidates = try await named(candidates, by: naming, emailProject: emailProject, names: names, chunks: chunks, projectNames: projectNames)
            let packages = await isPackage(candidates.map(\.url).filter { FolderWalk.documentPackages.contains($0.pathExtension.lowercased()) })
            candidates.removeAll { packages.contains($0.url) }
            found += Array(candidates.prefix(limit))
            if found.count >= perRequest { break }
        }
        return Array(found.prefix(perRequest))
    }

    // MARK: Files of other projects

    /// The words of a request that can name a file of another project, such as a name, a
    /// place, a product or a number: the words of what it asks for and of its sentence, as
    /// the index cuts them, without the words for any kind of document in the four languages,
    /// the words that only ask or point, such as send, 麻烦 or folder, words of one character,
    /// numbers of one or two digits, as days and months are, words of hiragana alone, in which
    /// Japanese writes its endings, dates, and the names of the email's people and of the
    /// user. Explain keeps names and dates from bringing in another project's passage too, see
    /// SearchTerms.withoutNamesAndDates, and here each word of a name counts on its own, as
    /// a request is cut into single words.
    static func namingWords(of request: FileRequest, people: [String], ownName: String) -> [String] {
        var text = (request.object + "\n" + request.sentence).precomposedStringWithCompatibilityMapping.lowercased()
        for phrase in kindPhrases {
            text = phrase.replacing(in: text)
        }
        var names: Set<String> = []
        for name in people + [ownName] {
            names.formUnion(SearchTerms.nameKeys(name, parts: true))
        }
        var words: [String] = []
        for word in ChunkSearch.words(in: text) where word.count > 1 && !words.contains(word) {
            guard word.contains(where: { $0.isLetter || $0.isNumber }), !(word.count < 3 && word.allSatisfy(\.isNumber)),
                  !askingWords.contains(word), !word.unicodeScalars.allSatisfy(isHiragana), !SearchTerms.isDate(word),
                  names.isDisjoint(with: SearchTerms.nameForms(of: word)) else { continue }
            words.append(word)
        }
        return words
    }

    /// `files` without those of other projects than `emailProject` that none of `words`
    /// names: in the file's name or folder, in its text, or in its project's name. The
    /// email's own files all stay, in their order.
    private static func named(
        _ files: [RequestedFile], by words: [String], emailProject: UUID?, names: FileNameSearch, chunks: ChunkSearch, projectNames: [UUID: String]
    ) async throws -> [RequestedFile] {
        let others = files.filter { $0.project != emailProject }.map { ChunkSearch.FileKey(project: $0.project, path: $0.url.path) }
        guard !others.isEmpty else { return files }
        var named: Set<ChunkSearch.FileKey> = []
        if !words.isEmpty {
            let asked = Set(words)
            for key in others where projectNames[key.project].map({ !asked.isDisjoint(with: ChunkSearch.words(in: $0)) }) ?? false {
                named.insert(key)
            }
            named.formUnion(try await names.named(others, by: words))
            // ChunkSearch reads a limited number of terms a query, so the words go in slices.
            for start in stride(from: 0, to: words.count, by: ChunkSearch.maximumTerms) {
                let slice = Array(words[start..<min(start + ChunkSearch.maximumTerms, words.count)])
                let read = try await chunks.passages(ChunkSearch.Query(text: "", terms: slice), in: others.filter { !named.contains($0) }, perFile: 1)
                named.formUnion(read.filter { $0.hits.contains { !$0.matchedTerms.isEmpty } }.map(\.key))
            }
        }
        return files.filter { $0.project == emailProject || named.contains(ChunkSearch.FileKey(project: $0.project, path: $0.url.path)) }
    }

    /// A word or phrase for a kind of document, as `namingWords` takes it out of a request.
    private nonisolated struct KindPhrase: Sendable {
        var phrase: String
        /// For a phrase in Latin letters, the phrase as a whole word, so plan stays in planning.
        var pattern: NSRegularExpression?

        func replacing(in text: String) -> String {
            guard let pattern else { return text.replacingOccurrences(of: phrase, with: " ") }
            return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
    }

    /// Every word for a kind of document in the four languages, lowercased, longest first, so
    /// a phrase goes before the words in it.
    private static let kindPhrases: [KindPhrase] = Set(DocumentKind.allCases.flatMap(\.terms.all).map { $0.precomposedStringWithCompatibilityMapping.lowercased() })
        .sorted { ($0.count, $0) > ($1.count, $1) }
        .map { phrase in
            let latin = phrase.unicodeScalars.allSatisfy { $0.isASCII || $0.properties.isAlphabetic && !ChineseText.isHan($0) && !isKana($0) }
            return KindPhrase(phrase: phrase, pattern: latin ? try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])") : nil)
        }

    /// Words that only ask, point or join, in the four languages, which name no file.
    private static let askingWords: Set<String> = Set("""
        a an the and or of to in on at for with by from about as into after before also both all any some every each other \
        more again too just only please kindly could would can will may might should do does did is are was were be been \
        have has had i me my we us our you your he him his she her they them their it its this that these those there here \
        what which who when where how why if so not no thanks thank hi hello dear best regards send sending sent share \
        forward email mail attach enclose provide give get need needs want like see look show check review use latest last \
        new newest updated final current recent version versions folder folders one ones \
        el la los las un una unos unas de del al en con por para sobre que me te se nos lo le les mi mis tu tus su sus \
        nuestro nuestra nuestros nuestras este esta estos estas ese esa esos esas podrías podrias puedes puede enviar \
        enviarme envíame envíanos mandar mándame compartir adjuntar pasar pásame favor gracias hola carpeta último última \
        nuevo nueva versión también todo todos toda todas mismo misma \
        你们 我们 他们 她们 咱们 一下 一份 一个 一些 这个 那个 这份 那份 这些 那些 麻烦 帮忙 帮我 发给 发我 转给 转发 发送 寄给 \
        传给 给我 看看 想看 需要 想要 可以 能否 是否 请问 顺便 方便 的话 参考 所有 全部 文件夹 最新 新版 最终 之前 以前 上次 \
        一起 回传 谢谢 您好 你好 这边 那边 \
        最新 最終 資料 フォルダ 送付 送信 共有 添付 確認 お願い
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static func isHiragana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x309F).contains(scalar.value)
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
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
        names: FileNameSearch, chunks: ChunkSearch, lists: Lists, searchTerms: [String]
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
        if lists.contains(.names), !asked.isEmpty {
            let named = try await names.search("", terms: asked, in: scope, limit: nameLimit).map(take)
            fused.append(named)
            eligible.formUnion(named)
            namedByTerms.formUnion(named)
        }
        if lists.contains(.names), !words.isEmpty {
            let named = try await names.search(words, in: scope, limit: nameLimit).map(take)
            fused.append(named)
            if asked.isEmpty {
                eligible.formUnion(named)
            }
        }
        // The text: chunks a word for the kind matches, or for a request without a kind,
        // chunks its own words match. Each file counts once, at its best chunk. Search terms
        // join the words of a kind's search, so they rank the chunks a word for the kind
        // matches and bring in none by themselves.
        let text = terms.isEmpty || searchTerms.isEmpty ? words : ([words] + searchTerms).joined(separator: " ")
        let query = ChunkSearch.Query(text: text, terms: terms, projects: scope, termsOnly: !terms.isEmpty, limit: chunkLimit)
        if lists.contains(.text), !terms.isEmpty || !words.isEmpty {
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
