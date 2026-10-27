import Foundation
import NaturalLanguage

/// Finds the chunks of project files that match a text, in the two full text tables of
/// the Projects database, see ProjectsDatabase and FolderIndex.
///
/// - The words table holds each chunk's words, which NLTokenizer found in each run of
///   Chinese characters and in the text around them, so a two character word such as 合同
///   matches. The trigram table holds the chunks with Chinese characters, so three
///   characters in a row match where NLTokenizer split the words another way.
/// - Both tables are ranked by BM25, and the two lists are merged by reciprocal rank fusion.
/// - A search may also carry search terms, such as the cleanup model gives for an email in
///   Chinese and English with other words for the same things, see SearchTerms. Each term
///   is one phrase: its words in a row in the words table, and a term of three or more
///   Chinese characters as a substring in the trigram table. The two lists of the terms
///   join the fusion with those of the text, so a chunk both find ranks first. Each hit
///   says which terms match it, each term searched alone in the same way, so a caller can
///   ask a chunk of another project for more than one term.
/// - The passages of the files the user chose for an email come from the same lists and the
///   same fusion, among the chunks of those files only, see `passages(_:in:perFile:)`.
/// - Every term goes into MATCH quoted, with its quotes doubled, so text from a mail or a
///   file never reads as FTS5 syntax. The query itself is a bound value, never SQL.
///
/// The phase 0 prototype (index.py) is the reference: the same stop words, term limits,
/// list lengths and fusion constant. Unlike it, a trigram query holds no Latin words, since
/// the trigram table holds only the chunks with Chinese.
nonisolated struct ChunkSearch: Sendable {
    /// What a search looks for.
    nonisolated struct Query: Sendable, Equatable {
        /// The text whose words are searched, such as an email's subject and own text.
        var text: String
        /// Search terms, each searched as a phrase, the first `maximumTerms` of them.
        var terms: [String] = []
        /// The projects searched, nil for all of them.
        var projects: [UUID]?
        /// Whether only the chunks a term matched count, such as for the files of other
        /// projects, which the words of an email alone never bring in.
        var termsOnly = false
        var limit = 6
    }

    /// A chunk that matched.
    nonisolated struct Hit: Sendable, Equatable {
        var chunk: Int64
        var project: UUID
        var file: URL
        /// The page number in a PDF and the slide number in a deck, nil for the other
        /// formats.
        var page: Int?
        /// The heading above the chunk's first line.
        var heading: String?
        /// The file's modification date when it was read.
        var modified: Date
        var text: String
        /// The hidden runs dropped from the chunk's file, see FileTextResult.hiddenRuns.
        /// Above zero, the file may hold text its reader does not see.
        var fileHiddenRuns: Int
        /// The fused rank score, higher is better. Zero for `newest(_:limit:)`.
        var score: Double
        /// The name of the chunk's sheet in a workbook, nil for the other formats.
        var sheet: String? = nil
        /// Whether the text was recognized in an image or on a scanned page.
        var recognized = false
        /// Whether a term of the query matches the chunk.
        var matchedTerm = false
        /// The query's terms that match the chunk, each searched alone as the lists of the
        /// terms search it, in the order of the query.
        var matchedTerms: [String] = []
    }

    /// A file the user chose for an email, by the project whose folder held it and its real
    /// path, as `index_files.path` holds it.
    nonisolated struct FileKey: Sendable, Hashable {
        var project: UUID
        var path: String
    }

    /// What a chosen file gives a prompt, see `passages(_:in:perFile:)`: its best passages, or
    /// its first chunk when none matches, or for a file the index holds without text its name
    /// and date, or nothing when the index does not hold it.
    nonisolated struct FilePassages: Sendable, Equatable {
        /// A file the index knows by its name only, or whose text it has not recognized yet.
        nonisolated struct Name: Sendable, Equatable {
            /// The project whose index holds the file now.
            var project: UUID
            var file: URL
            /// The file's modification date when the index listed it.
            var modified: Date
        }

        var key: FileKey
        /// Its passages, best first. Empty for a file without text and for one the index
        /// does not hold.
        var hits: [Hit] = []
        /// Its name and date, for a file the index holds without text.
        var name: Name?

        /// Whether the index holds the file, with text or by name.
        var isIndexed: Bool {
            !hits.isEmpty || name != nil
        }
    }

    /// The constant of reciprocal rank fusion: a chunk at rank r of a list adds 1 / (60 + r).
    static let fusionOffset = 60.0
    /// The chunks each table gives to the fusion.
    static let listLength = 50
    /// The rows of each table that count for the scores of the projects.
    static let scoredRows = 200
    /// The most words in one query.
    static let maximumWordTerms = 120
    /// The most trigrams in one query.
    static let maximumTrigramTerms = 200
    /// The characters of a text a query is made from. A long mail gives its terms well
    /// before the end, so the rest is not cut into words.
    static let maximumQueryCharacters = 20_000
    /// The most search terms in one query.
    static let maximumTerms = 12

    let database: ProjectsDatabase

    /// The best `limit` chunks for `text`, in `projects` or in all of them when nil. Off
    /// the main actor, since NLTokenizer and the full text queries take a while.
    @concurrent
    func search(_ text: String, in projects: [UUID]? = nil, limit: Int = 6) async throws -> [Hit] {
        try await search(Query(text: text, projects: projects, limit: limit))
    }

    /// The best chunks for the query's text and terms, in its projects. The lists of the
    /// text and of the terms are fused, and each hit says whether a term matched it. Without
    /// terms it gives what a search of the text alone gives, in the same order. Off the main
    /// actor, since NLTokenizer and the full text queries take a while.
    @concurrent
    func search(_ query: Query) async throws -> [Hit] {
        let terms = Array(query.terms.prefix(Self.maximumTerms))
        guard query.projects?.isEmpty != true, query.limit > 0, !query.termsOnly || !terms.isEmpty else { return [] }
        var lists: [[Int64]] = []
        for (table, match) in Self.queries(for: query.text) {
            lists.append(try await rows(table, match, in: query.projects))
        }
        var matched = Set<Int64>()
        for (table, match) in Self.termQueries(for: terms) {
            let list = try await rows(table, match, in: query.projects)
            matched.formUnion(list)
            lists.append(list)
        }
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (rank, chunk) in list.enumerated() {
                scores[chunk, default: 0] += 1 / (Self.fusionOffset + Double(rank))
            }
        }
        if query.termsOnly {
            scores = scores.filter { matched.contains($0.key) }
        }
        let best = scores.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.prefix(query.limit)
        guard !best.isEmpty else { return [] }
        let rows = try await database.run(Self.hitSQL + " WHERE c.id IN (SELECT value FROM json_each(?))", [.text(Self.json(best.map { String($0.key) }, quoted: false))])
        let hits = Dictionary(rows.compactMap { Self.hit($0, score: 0) }.map { ($0.chunk, $0) }, uniquingKeysWith: { first, _ in first })
        let termMatches = try await termsMatching(terms, among: best.map(\.key))
        return best.compactMap { chunk, score in
            hits[chunk].map { hit in
                var hit = hit
                hit.score = score
                hit.matchedTerms = termMatches[chunk] ?? []
                // A list of the terms holds a chunk that one term alone matches, but a chunk
                // past the end of those lists can still match one.
                hit.matchedTerm = matched.contains(chunk) || !hit.matchedTerms.isEmpty
                return hit
            }
        }
    }

    /// The passages of the files the user chose for an email, in their order: the best
    /// `perFile` of each for the query's text and terms, ranked as `search(_:)` ranks them with
    /// the same lists and the same fusion, but among the chunks of these files only. A file
    /// with no chunk that matches gives its first chunk, a file the index holds without text
    /// gives its name and date, and a file the index does not hold gives nothing. A file is
    /// looked up in the project of its key, or else by its path in any project, as after its
    /// folder moved to another project. The query's projects, limit and `termsOnly` do not
    /// count. Every value is bound, and the paths only ever as parameters. Off the main actor,
    /// since NLTokenizer and the full text queries take a while.
    @concurrent
    func passages(_ query: Query, in files: [FileKey], perFile: Int) async throws -> [FilePassages] {
        var found = files.map { FilePassages(key: $0) }
        // The row of each file, by its project and path, which the index holds once.
        var rows: [String: (id: Int64, place: Int)] = [:]
        for (place, key) in files.enumerated() {
            let row = try await database.run(
                "SELECT id, project, path, modified FROM index_files WHERE path = ?1 ORDER BY project = ?2 DESC, id LIMIT 1",
                [.text(key.path), .text(key.project.uuidString)]).first
            guard let row, row.count == 4, let id = row[0].integer, let project = row[1].text.flatMap(UUID.init(uuidString:)),
                  let path = row[2].text, let modified = row[3].real else { continue }
            rows[project.uuidString + "\u{0}" + path] = (id, place)
            found[place].name = FilePassages.Name(project: project, file: URL(fileURLWithPath: path), modified: Date(timeIntervalSince1970: modified))
        }
        guard !rows.isEmpty else { return found }
        let ids = Self.json(rows.values.map(\.id).sorted().map(String.init), quoted: false)
        let terms = Array(query.terms.prefix(Self.maximumTerms))
        var scores: [Int64: Double] = [:]
        for (table, match) in Self.queries(for: query.text) + Self.termQueries(for: terms) {
            let list = try await database.run(Self.fileMatchSQL(table), [.text(match), .text(ids)]).compactMap { $0.first?.integer }
            for (rank, chunk) in list.enumerated() {
                scores[chunk, default: 0] += 1 / (Self.fusionOffset + Double(rank))
            }
        }
        var hits: [Int: [Hit]] = [:]
        if !scores.isEmpty {
            let matched = try await database.run(Self.hitSQL + " WHERE c.id IN (SELECT value FROM json_each(?))", [.text(Self.json(scores.keys.sorted().map(String.init), quoted: false))])
            for row in matched {
                guard var hit = Self.hit(row, score: 0), let place = rows[hit.project.uuidString + "\u{0}" + hit.file.path]?.place else { continue }
                hit.score = scores[hit.chunk] ?? 0
                hits[place, default: []].append(hit)
            }
        }
        for (id, place) in rows.values {
            var best = Array((hits[place] ?? []).sorted { ($0.score, -$0.chunk) > ($1.score, -$1.chunk) }.prefix(max(perFile, 1)))
            if best.isEmpty {
                // A file with text that nothing of the query matches gives its start.
                best = try await database.run(Self.hitSQL + " WHERE c.file = ? ORDER BY c.id LIMIT 1", [.integer(id)]).compactMap { Self.hit($0, score: 0) }
            } else {
                let matches = try await termsMatching(terms, among: best.map(\.chunk))
                for index in best.indices {
                    best[index].matchedTerms = matches[best[index].chunk] ?? []
                    best[index].matchedTerm = !best[index].matchedTerms.isEmpty
                }
            }
            if !best.isEmpty {
                found[place].hits = best
                found[place].name = nil
            }
        }
        return found
    }

    /// The terms that match each of `chunks`, each term alone as the lists of the terms
    /// search it: as a phrase in the words table, and a term of three or more Chinese
    /// characters as a substring in the trigram table too. In the order of `terms`. One
    /// query a table, each term a bound value.
    private func termsMatching(_ terms: [String], among chunks: [Int64]) async throws -> [Int64: [String]] {
        guard !terms.isEmpty, !chunks.isEmpty else { return [:] }
        var found: [Int64: Set<Int>] = [:]
        let tables: [(table: String, query: ([String]) -> String?)] = [("index_chunk_words", Self.termWordQuery), ("index_chunk_trigrams", Self.termTrigramQuery)]
        for (table, query) in tables {
            var parameters: [ProjectsDatabase.Value] = [.text(Self.json(chunks.map(String.init), quoted: false))]
            var selects: [String] = []
            for (index, term) in terms.enumerated() {
                guard let match = query([term]) else { continue }
                parameters.append(.text(match))
                selects.append("SELECT rowid, \(index) FROM \(table) WHERE \(table) MATCH ?\(parameters.count) AND rowid IN (SELECT value FROM json_each(?1))")
            }
            guard !selects.isEmpty else { continue }
            for row in try await database.run(selects.joined(separator: " UNION ALL "), parameters) {
                guard row.count == 2, let chunk = row[0].integer, let index = row[1].integer, terms.indices.contains(Int(index)) else { continue }
                found[chunk, default: []].insert(Int(index))
            }
        }
        return found.mapValues { $0.sorted().map { terms[$0] } }
    }

    /// The chunks one table gives for a MATCH query, best first, in `projects` or in all.
    private func rows(_ table: String, _ match: String, in projects: [UUID]?) async throws -> [Int64] {
        var parameters: [ProjectsDatabase.Value] = [.text(match)]
        if let projects { parameters.append(.text(Self.json(projects.map(\.uuidString)))) }
        return try await database.run(Self.matchSQL(table, filtered: projects != nil), parameters).compactMap { $0.first?.integer }
    }

    /// The chunks of a project's most recently changed files, a file's chunks in order, to
    /// fill a prompt when the search finds little.
    @concurrent
    func newest(_ project: UUID, limit: Int) async throws -> [Hit] {
        guard limit > 0 else { return [] }
        let rows = try await database.run(
            Self.hitSQL + " WHERE c.project = ? ORDER BY c.modified DESC, c.file, c.id LIMIT ?",
            [.text(project.uuidString), .integer(Int64(limit))])
        return rows.compactMap { Self.hit($0, score: 0) }
    }

    /// The full text score of each project that matches `text`, higher is better and always
    /// above zero, for the sorting vote, see SortingSignals.gather. A project's score adds
    /// its best BM25 in each table, turned around, as the prototype does. Projects without
    /// a match are left out.
    @concurrent
    func projectScores(_ text: String, among projects: [UUID]? = nil) async throws -> [UUID: Double] {
        guard projects?.isEmpty != true else { return [:] }
        var scores: [UUID: Double] = [:]
        for (table, query) in Self.queries(for: text) {
            var parameters: [ProjectsDatabase.Value] = [.text(query)]
            if let projects { parameters.append(.text(Self.json(projects.map(\.uuidString)))) }
            let sql = """
                SELECT project, min(score) FROM (SELECT c.project AS project, bm25(\(table)) AS score
                FROM \(table) JOIN index_chunks c ON c.id = \(table).rowid WHERE \(table) MATCH ?1\(projects == nil ? "" : Self.projectFilter)
                ORDER BY score LIMIT \(Self.scoredRows)) GROUP BY project
                """
            for row in try await database.run(sql, parameters) {
                guard row.count == 2, let id = row[0].text.flatMap(UUID.init(uuidString:)), let best = row[1].real, best < 0 else { continue }
                scores[id, default: 0] -= best
            }
        }
        return scores
    }

    // MARK: Text in the index

    /// The words of a text as the words table holds them: compatibility forms folded
    /// (NFKC), lowercased, and cut by NLTokenizer, each run of Chinese characters on its
    /// own, since NLTokenizer drops most Chinese words when a Chinese and an English
    /// sentence share a string (phase 0).
    static func words(in text: String) -> [String] {
        let form = text.precomposedStringWithCompatibilityMapping.lowercased()
        let other = NLTokenizer(unit: .word)
        let chinese = NLTokenizer(unit: .word)
        chinese.setLanguage(.simplifiedChinese)
        var words: [String] = []
        for run in runs(of: form) {
            let string = String(run.text)
            let tokenizer = run.isChinese ? chinese : other
            tokenizer.string = string
            tokenizer.enumerateTokens(in: string.startIndex..<string.endIndex) { range, _ in
                words.append(String(string[range]))
                return true
            }
        }
        return words
    }

    /// What the words table holds for a text.
    static func indexedWords(_ text: String) -> String {
        words(in: text).joined(separator: " ")
    }

    /// What the trigram table holds for a text: compatibility forms folded, so full width
    /// letters and digits match their plain forms. The trigram tokenizer ignores case.
    static func indexedTrigramText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    /// Whether a text holds a Chinese character, so it goes into the trigram table too.
    static func hasChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: ChineseText.isHan)
    }

    // MARK: Queries

    /// The MATCH query for the words table: the words of the text's first
    /// `maximumQueryCharacters` without stop words and single letters or characters, each
    /// once, at most `maximumWordTerms`. Nil when none is left.
    static func wordQuery(_ text: String) -> String? {
        var terms: [String] = []
        var seen = Set<String>()
        for word in words(in: String(text.prefix(maximumQueryCharacters))) {
            let term = cleaned(word)
            guard term.contains(where: { $0.isLetter || $0.isNumber }), !stopWords.contains(term) else { continue }
            if term.count == 1, term.first?.isNumber != true { continue }
            guard seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == maximumWordTerms { break }
        }
        return matchQuery(terms)
    }

    /// The MATCH query for the trigram table: every three Chinese characters in a row in the
    /// text's first `maximumQueryCharacters`, each once, at most `maximumTrigramTerms`. Nil
    /// when there are none. Latin words are left to the words table, since the trigram table
    /// holds only chunks with Chinese, and a Latin word there would favor them over chunks in
    /// English.
    static func trigramQuery(_ text: String) -> String? {
        let form = cleaned(indexedTrigramText(String(text.prefix(maximumQueryCharacters))))
        var terms: [String] = []
        var seen = Set<String>()
        collecting: for run in runs(of: form) where run.isChinese {
            let characters = Array(run.text)
            guard characters.count >= 3 else { continue }
            for start in 0...(characters.count - 3) {
                let term = String(characters[start..<(start + 3)])
                guard seen.insert(term).inserted else { continue }
                terms.append(term)
                if terms.count == maximumTrigramTerms { break collecting }
            }
        }
        return matchQuery(terms)
    }

    /// The MATCH query of search terms for the words table: each term as one phrase of its
    /// words, cut and folded as the table holds them, so a term of several words matches
    /// them in a row. A term without a letter or a digit, one of stop words only, and one of
    /// a single letter or character other than a digit are left out, and so is a phrase
    /// seen before. Nil when none is left.
    static func termWordQuery(_ terms: [String]) -> String? {
        var phrases: [String] = []
        var seen = Set<String>()
        for term in terms.prefix(maximumTerms) {
            let words = words(in: String(term.prefix(maximumTermCharacters))).map(cleaned).filter { !$0.isEmpty }
            guard words.contains(where: { $0.contains(where: { $0.isLetter || $0.isNumber }) }),
                  !words.allSatisfy(stopWords.contains) else { continue }
            if words.count == 1, words[0].count == 1, words[0].first?.isNumber != true { continue }
            let phrase = words.joined(separator: " ")
            guard seen.insert(phrase).inserted else { continue }
            phrases.append(phrase)
        }
        return matchQuery(phrases)
    }

    /// The MATCH query of search terms for the trigram table: each term of three or more
    /// Chinese characters and nothing else, in compatibility form, which the table matches
    /// as a substring. Shorter Chinese terms and Latin ones are left to the words table, as
    /// `trigramQuery(_:)` leaves Latin words out. Nil when none is left.
    static func termTrigramQuery(_ terms: [String]) -> String? {
        var strings: [String] = []
        var seen = Set<String>()
        for term in terms.prefix(maximumTerms) {
            let form = cleaned(indexedTrigramText(String(term.prefix(maximumTermCharacters))))
            guard form.count >= 3, form.unicodeScalars.allSatisfy(ChineseText.isHan), seen.insert(form).inserted else { continue }
            strings.append(form)
        }
        return matchQuery(strings)
    }

    /// The characters of a term a query reads at most. SearchTerms keeps terms far shorter.
    private static let maximumTermCharacters = 80

    /// Terms joined by OR, each quoted.
    static func matchQuery(_ terms: [String]) -> String? {
        terms.isEmpty ? nil : terms.map(quoted).joined(separator: " OR ")
    }

    /// A term as an FTS5 string: in double quotes, with each double quote in it doubled, so
    /// no operator, column filter, prefix star or bracket in it counts. Control characters,
    /// such as NUL, are dropped.
    static func quoted(_ term: String) -> String {
        "\"" + cleaned(term).replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func queries(for text: String) -> [(table: String, query: String)] {
        [("index_chunk_words", wordQuery(text)), ("index_chunk_trigrams", trigramQuery(text))]
            .compactMap { table, query in query.map { (table, $0) } }
    }

    private static func termQueries(for terms: [String]) -> [(table: String, query: String)] {
        guard !terms.isEmpty else { return [] }
        return [("index_chunk_words", termWordQuery(terms)), ("index_chunk_trigrams", termTrigramQuery(terms))]
            .compactMap { table, query in query.map { (table, $0) } }
    }

    /// Whether a word, as `words(in:)` gives it, is one that queries leave out.
    static func isStopWord(_ word: String) -> Bool {
        stopWords.contains(word)
    }

    /// Words the prototype leaves out of queries, in Chinese and English.
    private static let stopWords: Set<String> = Set("""
        的 了 和 是 在 我 你 您 他 她 们 我们 你们 也 都 就 吗 呢 吧 啊 好 请 一下 一个 这 那 这个 那个 有 没有 \
        to the a an of and or in on for is are be we you i it this that with at by from as will can could would \
        please thanks thank hi dear best regards
        """.split(separator: " ").map(String.init))

    /// A term without control characters, such as NUL.
    private static func cleaned(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .control }))
    }

    /// The text in runs of Chinese characters and runs of everything else, in order.
    private static func runs(of text: String) -> [(text: Substring, isChinese: Bool)] {
        var runs: [(text: Substring, isChinese: Bool)] = []
        var start = text.startIndex
        var current: Bool?
        var index = text.startIndex
        while index < text.endIndex {
            let isChinese = text[index].unicodeScalars.first.map(ChineseText.isHan) ?? false
            if let current, current != isChinese {
                runs.append((text[start..<index], current))
                start = index
            }
            current = isChinese
            index = text.index(after: index)
        }
        if let current, start < text.endIndex {
            runs.append((text[start...], current))
        }
        return runs
    }

    // MARK: Rows

    private static let projectFilter = " AND c.project IN (SELECT value FROM json_each(?2))"

    private static func matchSQL(_ table: String, filtered: Bool) -> String {
        "SELECT \(table).rowid FROM \(table) JOIN index_chunks c ON c.id = \(table).rowid WHERE \(table) MATCH ?1"
            + (filtered ? projectFilter : "") + " ORDER BY bm25(\(table)) LIMIT \(listLength)"
    }

    /// The MATCH query of a table among the chunks of the files whose rows ?2 lists, as a
    /// JSON array of their ids.
    private static func fileMatchSQL(_ table: String) -> String {
        "SELECT \(table).rowid FROM \(table) JOIN index_chunks c ON c.id = \(table).rowid WHERE \(table) MATCH ?1"
            + " AND c.file IN (SELECT value FROM json_each(?2)) ORDER BY bm25(\(table)) LIMIT \(listLength)"
    }

    private static let hitSQL = """
        SELECT c.id, c.project, f.path, c.page, c.heading, c.modified, c.text, f.hidden_runs, c.sheet, c.recognized
        FROM index_chunks c JOIN index_files f ON f.id = c.file
        """

    private static func hit(_ row: [ProjectsDatabase.Value], score: Double) -> Hit? {
        guard row.count == 10, let chunk = row[0].integer, let project = row[1].text.flatMap(UUID.init(uuidString:)),
              let path = row[2].text, let modified = row[5].real, let text = row[6].text else { return nil }
        return Hit(
            chunk: chunk, project: project, file: URL(fileURLWithPath: path), page: row[3].integer.map(Int.init),
            heading: row[4].text, modified: Date(timeIntervalSince1970: modified), text: text,
            fileHiddenRuns: Int(row[7].integer ?? 0), score: score, sheet: row[8].text, recognized: row[9].integer == 1)
    }

    /// A JSON array of the values, for json_each. UUIDs and numbers need no escaping.
    private static func json(_ values: [String], quoted: Bool = true) -> String {
        "[" + values.map { quoted ? "\"\($0)\"" : $0 }.joined(separator: ",") + "]"
    }
}
