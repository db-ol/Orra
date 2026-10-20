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
/// - Every term goes into MATCH quoted, with its quotes doubled, so text from a mail or a
///   file never reads as FTS5 syntax. The query itself is a bound value, never SQL.
///
/// The phase 0 prototype (index.py) is the reference: the same stop words, term limits,
/// list lengths and fusion constant. Unlike it, a trigram query holds no Latin words, since
/// the trigram table holds only the chunks with Chinese.
nonisolated struct ChunkSearch: Sendable {
    /// A chunk that matched.
    nonisolated struct Hit: Sendable, Equatable {
        var chunk: Int64
        var project: UUID
        var file: URL
        /// The page number in a PDF, nil for the other formats.
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

    let database: ProjectsDatabase

    /// The best `limit` chunks for `text`, in `projects` or in all of them when nil. Off
    /// the main actor, since NLTokenizer and the full text queries take a while.
    @concurrent
    func search(_ text: String, in projects: [UUID]? = nil, limit: Int = 6) async throws -> [Hit] {
        guard projects?.isEmpty != true, limit > 0 else { return [] }
        var lists: [[Int64]] = []
        for (table, query) in Self.queries(for: text) {
            var parameters: [ProjectsDatabase.Value] = [.text(query)]
            if let projects { parameters.append(.text(Self.json(projects.map(\.uuidString)))) }
            let rows = try await database.run(Self.matchSQL(table, filtered: projects != nil), parameters)
            lists.append(rows.compactMap { $0.first?.integer })
        }
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (rank, chunk) in list.enumerated() {
                scores[chunk, default: 0] += 1 / (Self.fusionOffset + Double(rank))
            }
        }
        let best = scores.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.prefix(limit)
        guard !best.isEmpty else { return [] }
        let rows = try await database.run(Self.hitSQL + " WHERE c.id IN (SELECT value FROM json_each(?))", [.text(Self.json(best.map { String($0.key) }, quoted: false))])
        let hits = Dictionary(rows.compactMap { Self.hit($0, score: 0) }.map { ($0.chunk, $0) }, uniquingKeysWith: { first, _ in first })
        return best.compactMap { chunk, score in
            hits[chunk].map { hit in
                var hit = hit
                hit.score = score
                return hit
            }
        }
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

    /// The MATCH query for the words table: the text's words without stop words and single
    /// letters or characters, each once, at most `maximumWordTerms`. Nil when none is left.
    static func wordQuery(_ text: String) -> String? {
        var terms: [String] = []
        var seen = Set<String>()
        for word in words(in: text) {
            let term = cleaned(word)
            guard term.contains(where: { $0.isLetter || $0.isNumber }), !stopWords.contains(term) else { continue }
            if term.count == 1, term.first?.isNumber != true { continue }
            guard seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == maximumWordTerms { break }
        }
        return matchQuery(terms)
    }

    /// The MATCH query for the trigram table: every three Chinese characters in a row, each
    /// once, at most `maximumTrigramTerms`. Nil when there are none. Latin words are left to
    /// the words table, since the trigram table holds only chunks with Chinese, and a Latin
    /// word there would favor them over chunks in English.
    static func trigramQuery(_ text: String) -> String? {
        let form = cleaned(indexedTrigramText(text))
        var terms: [String] = []
        var seen = Set<String>()
        func add(_ term: String) {
            if terms.count < maximumTrigramTerms, seen.insert(term).inserted { terms.append(term) }
        }
        for run in runs(of: form) where run.isChinese {
            let characters = Array(run.text)
            guard characters.count >= 3 else { continue }
            for start in 0...(characters.count - 3) {
                add(String(characters[start..<(start + 3)]))
            }
        }
        return matchQuery(terms)
    }

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

    private static let hitSQL = """
        SELECT c.id, c.project, f.path, c.page, c.heading, c.modified, c.text, f.hidden_runs
        FROM index_chunks c JOIN index_files f ON f.id = c.file
        """

    private static func hit(_ row: [ProjectsDatabase.Value], score: Double) -> Hit? {
        guard row.count == 8, let chunk = row[0].integer, let project = row[1].text.flatMap(UUID.init(uuidString:)),
              let path = row[2].text, let modified = row[5].real, let text = row[6].text else { return nil }
        return Hit(
            chunk: chunk, project: project, file: URL(fileURLWithPath: path), page: row[3].integer.map(Int.init),
            heading: row[4].text, modified: Date(timeIntervalSince1970: modified), text: text,
            fileHiddenRuns: Int(row[7].integer ?? 0), score: score)
    }

    /// A JSON array of the values, for json_each. UUIDs and numbers need no escaping.
    private static func json(_ values: [String], quoted: Bool = true) -> String {
        "[" + values.map { quoted ? "\"\($0)\"" : $0 }.joined(separator: ",") + "]"
    }
}
