import Foundation

/// Finds the files of the project folders by their names and folders, in the two name
/// tables of the Projects database, see `FolderIndex.fileTypesMigration`. It finds every
/// file the index lists, those it knows by name only too, such as a drawing or an archive.
/// It stays apart from ChunkSearch, which finds passages of text, since a file found by its
/// name alone has no passage to give a prompt.
///
/// - The queries are ChunkSearch's words query and trigram query, every term quoted and the
///   query a bound value, so a name in a mail never reads as FTS5 syntax.
/// - Each table ranks its matches by BM25 with a file's name counting four times its
///   folder, and the two lists are merged by reciprocal rank fusion with ChunkSearch's
///   constant. Files whose fused scores are equal keep the order of the words list.
/// - A file whose whole name is the text, with or without its extension, comes first. The
///   trigram list sees only Chinese, so it cannot tell 现场玻璃0380.docx from
///   瓷砖现场玻璃1141.png by their numbers, and a name an email gives whole means that file.
/// - A search may also carry terms, such as the words for a kind of document in four
///   languages and the file names an email gives, see RequestedFiles. Each term is one
///   phrase, as ChunkSearch searches its terms: its words in a row in the words table, and a
///   term of three or more Chinese characters as a substring in the trigram table. Their two
///   lists join the fusion, so "floor plan" finds floor-plan-v3.pdf as a phrase and by its
///   words, above Project plan.docx, which shares only plan. A file whose whole name is a
///   term comes first too.
nonisolated struct FileNameSearch: Sendable {
    /// A file that matched.
    nonisolated struct Hit: Sendable, Equatable {
        /// The file's row in index_files.
        var file: Int64
        var project: UUID
        var url: URL
        var size: Int64
        /// The file's modification date when the index listed it.
        var modified: Date
        /// Why the index holds no text of the file, nil when it holds its text. A file that
        /// waits for recognition has `waitsForRecognition`, and any other reason means the
        /// index knows the file by name only. A reason a later Orra wrote reads as
        /// `unsupportedFormat`.
        var skip: FileSkipReason?
        /// The fused rank score, higher is better.
        var score: Double
    }

    /// The weight of a file's name and of its folder in BM25.
    static let nameWeight = 4.0
    static let folderWeight = 1.0

    let database: ProjectsDatabase

    /// The most terms one search reads.
    static let maximumTerms = 60

    /// The best `limit` files whose names or folders match `text` or one of `terms`, in
    /// `projects` or in all of them when nil. Without terms it gives what a search of the
    /// text alone gives, in the same order. Off the main actor, since NLTokenizer and the
    /// full text queries take a while.
    @concurrent
    func search(_ text: String, terms: [String] = [], in projects: [UUID]? = nil, limit: Int = 20) async throws -> [Hit] {
        guard projects?.isEmpty != true, limit > 0 else { return [] }
        let terms = Array(terms.prefix(Self.maximumTerms))
        var lists: [[Int64]] = []
        var textWords: [Int64] = []
        if let query = ChunkSearch.wordQuery(text) {
            textWords = try await matches("index_file_names", query, in: projects)
            lists.append(textWords)
        }
        if let query = ChunkSearch.trigramQuery(text) {
            lists.append(try await matches("index_file_name_trigrams", query, in: projects))
        }
        // The terms give one list: the matches of the words table, then those only the
        // trigram table finds, so a Chinese name that both find counts once for a term.
        let termQueries = Self.termQueries(terms)
        if termQueries.words != nil || termQueries.trigrams != nil {
            var found: [Int64] = []
            if let query = termQueries.words {
                found = try await matches("index_file_names", query, in: projects)
            }
            if let query = termQueries.trigrams {
                let known = Set(found)
                found += try await matches("index_file_name_trigrams", query, in: projects).filter { !known.contains($0) }
            }
            lists.append(found)
        }
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (rank, file) in list.enumerated() {
                scores[file, default: 0] += 1 / (ChunkSearch.fusionOffset + Double(rank))
            }
        }
        // The text's list of the words table breaks ties.
        var wordRanks: [Int64: Int] = [:]
        for (rank, file) in textWords.enumerated() where wordRanks[file] == nil {
            wordRanks[file] = rank
        }
        let ranked = scores.sorted { first, second in
            if first.value != second.value { return first.value > second.value }
            let firstRank = wordRanks[first.key] ?? .max, secondRank = wordRanks[second.key] ?? .max
            return firstRank != secondRank ? firstRank < secondRank : first.key < second.key
        }
        guard !ranked.isEmpty else { return [] }
        let rows = try await database.run(
            "SELECT f.id, f.project, f.path, f.size, f.modified, f.skip, n.name FROM index_files f LEFT JOIN index_file_names n ON n.rowid = f.id"
                + " WHERE f.id IN (SELECT value FROM json_each(?))",
            [.text(Self.json(ranked.map { String($0.key) }))])
        var hits: [Int64: (hit: Hit, name: String?)] = [:]
        for row in rows where row.count == 7 {
            guard let file = row[0].integer, let project = row[1].text.flatMap(UUID.init(uuidString:)), let path = row[2].text,
                  let size = row[3].integer, let modified = row[4].real else { continue }
            let skip = row[5].text.map { FileSkipReason(rawValue: $0) ?? .unsupportedFormat }
            hits[file] = (Hit(
                file: file, project: project, url: URL(fileURLWithPath: path), size: size,
                modified: Date(timeIntervalSince1970: modified), skip: skip, score: 0), row[6].text)
        }
        // The words of the text and of each term as the name table holds a name, for a text
        // short enough to be one.
        let names = ([text] + terms).filter { $0.count <= ChunkSearch.maximumQueryCharacters }.map { ChunkSearch.indexedWords(FolderIndex.searchableText($0)) }
        var whole: [Hit] = []
        var rest: [Hit] = []
        for (file, score) in ranked {
            guard var found = hits[file] else { continue }
            found.hit.score = score
            if names.contains(where: { Self.isWholeName($0, entry: found.name, of: found.hit.url) }) {
                whole.append(found.hit)
            } else {
                rest.append(found.hit)
            }
        }
        return Array((whole + rest).prefix(limit))
    }

    /// Whether `words` are a file's whole name, with or without its extension: its name entry,
    /// or the entry without the extension's words at its end.
    private static func isWholeName(_ words: String, entry: String?, of file: URL) -> Bool {
        guard !words.isEmpty, let entry else { return false }
        if entry == words { return true }
        guard entry.hasPrefix(words + " ") else { return false }
        return entry.dropFirst(words.count + 1) == ChunkSearch.indexedWords(file.pathExtension)
    }

    /// The rows of the file at a real path, one for each project whose folders hold it, as
    /// the index lists it now, with score 0. Empty for a path the index does not hold. For a
    /// file the user adds to a reply, which must be one the index holds.
    @concurrent
    func files(atPath path: String) async throws -> [Hit] {
        try await database.run("SELECT id, project, path, size, modified, skip FROM index_files WHERE path = ? ORDER BY id", [.text(path)])
            .compactMap { row in
                guard row.count == 6, let file = row[0].integer, let project = row[1].text.flatMap(UUID.init(uuidString:)),
                      let path = row[2].text, let size = row[3].integer, let modified = row[4].real else { return nil }
                return Hit(
                    file: file, project: project, url: URL(fileURLWithPath: path), size: size,
                    modified: Date(timeIntervalSince1970: modified), skip: row[5].text.map { FileSkipReason(rawValue: $0) ?? .unsupportedFormat }, score: 0)
            }
    }

    /// The files one name table gives for a MATCH query, best first, in `projects` or in all.
    private func matches(_ table: String, _ query: String, in projects: [UUID]?) async throws -> [Int64] {
        var parameters: [ProjectsDatabase.Value] = [.text(query)]
        var sql = "SELECT \(table).rowid FROM \(table) JOIN index_files f ON f.id = \(table).rowid WHERE \(table) MATCH ?1"
        if let projects {
            parameters.append(.text(Self.json(projects.map { "\"\($0.uuidString)\"" })))
            sql += " AND f.project IN (SELECT value FROM json_each(?2))"
        }
        sql += " ORDER BY bm25(\(table), \(Self.nameWeight), \(Self.folderWeight)) LIMIT \(ChunkSearch.listLength)"
        return try await database.run(sql, parameters).compactMap { $0.first?.integer }
    }

    /// The MATCH queries of the terms for the two name tables, each term a phrase as
    /// ChunkSearch writes them for chunks, every term and not only ChunkSearch's first ones.
    private static func termQueries(_ terms: [String]) -> (words: String?, trigrams: String?) {
        guard !terms.isEmpty else { return (nil, nil) }
        let slices = stride(from: 0, to: terms.count, by: ChunkSearch.maximumTerms).map { Array(terms[$0..<min($0 + ChunkSearch.maximumTerms, terms.count)]) }
        let words = slices.compactMap(ChunkSearch.termWordQuery)
        let trigrams = slices.compactMap(ChunkSearch.termTrigramQuery)
        return (words.isEmpty ? nil : words.joined(separator: " OR "), trigrams.isEmpty ? nil : trigrams.joined(separator: " OR "))
    }

    /// A JSON array of values written as JSON already, for json_each.
    private static func json(_ values: [String]) -> String {
        "[" + values.joined(separator: ",") + "]"
    }
}
