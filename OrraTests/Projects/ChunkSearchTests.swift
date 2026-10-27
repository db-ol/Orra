import Foundation
import Testing
@testable import Orra

/// Full text search over chunks written as FolderIndex writes them, in a database in a
/// temporary root. The texts are made up for these tests.
struct ChunkSearchTests {
    let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("ChunkSearchTests-\(UUID().uuidString)", isDirectory: true))
    let alpha = UUID()
    let beta = UUID()

    private func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
    }

    /// Adds a file with one chunk for each text, as FolderIndex writes them. Returns the
    /// chunks' IDs.
    @discardableResult
    private func add(
        _ texts: [String], file: String, project: UUID, modified: Double = 1_760_000_000, hiddenRuns: Int = 0,
        page: Int? = nil, heading: String? = nil, to database: ProjectsDatabase
    ) async throws -> [Int64] {
        try await database.transaction { database in
            try database.run(
                "INSERT INTO index_files (project, path, size, modified, hidden_runs, text_bytes, chunks) VALUES (?, ?, 1, ?, ?, 1, ?)",
                [.text(project.uuidString), .text("/Projects/\(file)"), .real(modified), .integer(Int64(hiddenRuns)), .integer(Int64(texts.count))])
            let fileID = database.lastInsertedRow
            var ids: [Int64] = []
            for text in texts {
                try database.run(
                    "INSERT INTO index_chunks (file, project, page, heading, modified, text, chinese) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.integer(fileID), .text(project.uuidString), page.map { .integer(Int64($0)) } ?? .null,
                     heading.map { .text($0) } ?? .null, .real(modified), .text(text), .integer(ChunkSearch.hasChinese(text) ? 1 : 0)])
                let id = database.lastInsertedRow
                let name = (file as NSString).deletingPathExtension
                try database.run(
                    "INSERT INTO index_chunk_words (rowid, name, words) VALUES (?, ?, ?)",
                    [.integer(id), .text(ChunkSearch.indexedWords(name)), .text(ChunkSearch.indexedWords(text))])
                if ChunkSearch.hasChinese(text) {
                    try database.run(
                        "INSERT INTO index_chunk_trigrams (rowid, name, text) VALUES (?, ?, ?)",
                        [.integer(id), .text(ChunkSearch.indexedTrigramText(name)), .text(ChunkSearch.indexedTrigramText(text))])
                }
                ids.append(id)
            }
            return ids
        }
    }

    /// The chunks one table finds for a query.
    private func matches(_ query: String?, in table: String, _ database: ProjectsDatabase) async throws -> [Int64] {
        guard let query else { return [] }
        return try await database.run("SELECT rowid FROM \(table) WHERE \(table) MATCH ? ORDER BY rowid", [.text(query)]).compactMap { $0.first?.integer }
    }

    @Test func aTwoCharacterWordMatchesThroughTheWordsTable() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let ids = try await add(["合同付款条款需要确认。"], file: "合同.md", project: alpha, to: database)
        #expect(ChunkSearch.words(in: "合同付款条款需要确认。") == ["合同", "付款", "条款", "需要", "确认"])
        #expect(ChunkSearch.wordQuery("合同") == #""合同""#)
        // Trigrams need three characters.
        #expect(ChunkSearch.trigramQuery("合同") == nil)
        #expect(try await matches(ChunkSearch.wordQuery("合同"), in: "index_chunk_words", database) == ids)
        #expect(try await ChunkSearch(database: database).search("合同").map(\.chunk) == ids)
        await database.close()
    }

    /// NLTokenizer cuts 下周三和 into 下周 and 三和, so 周三 is not among the words. Three
    /// characters in a row still find the chunk through the trigram table.
    @Test func threeCharactersMatchThroughTrigramsWhereTheWordsWereCutAnotherWay() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let ids = try await add(["下周三和何立伟确认样品。"], file: "样品.md", project: alpha, to: database)
        #expect(try await matches(ChunkSearch.wordQuery("周三和何"), in: "index_chunk_words", database).isEmpty)
        #expect(try await matches(ChunkSearch.trigramQuery("周三和何"), in: "index_chunk_trigrams", database) == ids)
        #expect(try await ChunkSearch(database: database).search("周三和何").map(\.chunk) == ids)
        await database.close()
    }

    @Test func textWithoutChineseStaysOutOfTheTrigramTable() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let english = try await add(["The print run is 500 calendars."], file: "print.txt", project: alpha, to: database)
        let mixed = try await add(["Calendars 交货 next week."], file: "mixed.txt", project: alpha, to: database)
        #expect(try await database.run("SELECT rowid FROM index_chunk_trigrams").compactMap { $0.first?.integer } == mixed)
        #expect(try await database.run("SELECT chinese FROM index_chunks ORDER BY id") == [[.integer(0)], [.integer(1)]])
        // Case and full width forms fold.
        let hits = try await ChunkSearch(database: database).search("ＣＡＬＥＮＤＡＲＳ print")
        #expect(Set(hits.map(\.chunk)) == Set(english + mixed))
        #expect(hits.first?.chunk == english.first)
        await database.close()
    }

    @Test func termsAreQuotedSoNothingInThemIsSyntax() {
        #expect(ChunkSearch.quoted(#"say "hi""#) == #""say ""hi""""#)
        #expect(ChunkSearch.matchQuery(["a", #"b"c"#]) == #""a" OR "b""c""#)
        #expect(ChunkSearch.matchQuery([]) == nil)
        #expect(ChunkSearch.wordQuery("the and of 的 了 a 我") == nil)
        #expect(ChunkSearch.wordQuery("v3 合同 v3 3") == #""v3" OR "合同" OR "3""#)
        #expect(ChunkSearch.trigramQuery("合同付款 brief-v3.2 合同") == #""合同付" OR "同付款""#)
        #expect(ChunkSearch.trigramQuery("The print run") == nil)
    }

    /// Text from a mail can hold FTS5 syntax. Each piece stays a plain term: no error, no
    /// prefix match, no column filter, no NEAR.
    /// A query is made from the start of a long text only, so a long mail costs no more
    /// than its start.
    @Test func queriesComeFromTheStartOfALongText() throws {
        let long = "印刷合同 posters " + String(repeating: "灯具 lamps ", count: 3_000) + "海报设计 brochure"
        #expect(long.count > ChunkSearch.maximumQueryCharacters)
        let words = try #require(ChunkSearch.wordQuery(long))
        #expect(words.contains("\"posters\"") && words.contains("\"lamps\""))
        #expect(!words.contains("brochure"))
        let trigrams = try #require(ChunkSearch.trigramQuery(long))
        #expect(trigrams.contains("\"印刷合\""))
        #expect(!trigrams.contains("海报设"))
    }

    @Test func hostileTermsFindOnlyThemselves() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let calendars = try await add(["Calendars near the desk, 合同付款。"], file: "a.txt", project: alpha, to: database)
        let lamps = try await add(["Unrelated text about lamps."], file: "b.txt", project: alpha, to: database)
        let hostile = [
            "\"", String(repeating: "\"", count: 3), "*", "calend*", "^start", "-minus", "NEAR(calendars desk)", "col:x", "words:calendars", "name:a",
            "AND", "OR", "NOT", "(", ")", "a\u{0}b", "合同\"付款", "\\", "'; DROP TABLE index_chunks; --", "{name words}: lamps",
        ]
        for term in hostile {
            for table in ["index_chunk_words", "index_chunk_trigrams"] {
                let found = try await matches(ChunkSearch.matchQuery([term]), in: table, database)
                #expect(found.isEmpty || found == calendars, "\(term) in \(table)")
            }
        }
        // As syntax, each of these would match: a prefix, NEAR, a column filter and a set of
        // columns.
        for term in ["calend*", "NEAR(calendars desk)", "name:a", "{name words}: lamps"] {
            #expect(try await matches(ChunkSearch.matchQuery([term]), in: "index_chunk_words", database).isEmpty, "\(term)")
        }
        // A quote inside a term only ends a word.
        #expect(try await matches(ChunkSearch.matchQuery(["合同\"付款"]), in: "index_chunk_words", database) == calendars)
        let search = ChunkSearch(database: database)
        #expect(try await search.search("calend*").isEmpty)
        #expect(try await search.search("lamps NEAR(lamps text)").map(\.chunk) == lamps + calendars)
        #expect(try await search.search(hostile.joined(separator: " ")).map(\.chunk) == calendars + lamps)
        #expect(try await database.run("SELECT count(*) FROM index_chunks") == [[.integer(2)]])
        await database.close()
    }

    @Test func searchStaysInTheProjectsItIsGiven() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let inAlpha = try await add(["灯具采购合同已经签好。"], file: "a.md", project: alpha, to: database)
        let inBeta = try await add(["灯具采购合同还在谈。"], file: "b.md", project: beta, to: database)
        let search = ChunkSearch(database: database)
        #expect(try await search.search("灯具采购", in: [alpha]).map(\.chunk) == inAlpha)
        #expect(try await search.search("灯具采购", in: [beta]).map(\.chunk) == inBeta)
        #expect(Set(try await search.search("灯具采购").map(\.chunk)) == Set(inAlpha + inBeta))
        #expect(try await search.search("灯具采购", in: []).isEmpty)
        #expect(try await search.search("灯具采购", in: [UUID()]).isEmpty)
        #expect(try await search.search("灯具采购", limit: 0).isEmpty)
        await database.close()
    }

    /// Reciprocal rank fusion: a chunk both tables find goes before one only one finds.
    @Test func chunksBothTablesFindComeFirst() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        // 厂交货 is one word, 交货, for the words table, and one trigram.
        let wordsOnly = try await add(["交货时间：印刷厂。"], file: "a.md", project: alpha, to: database)
        let both = try await add(["印刷厂交货时间改到周五。"], file: "b.md", project: alpha, to: database)
        #expect(try await matches(ChunkSearch.trigramQuery("厂交货"), in: "index_chunk_trigrams", database) == both)
        #expect(try await matches(ChunkSearch.wordQuery("厂交货"), in: "index_chunk_words", database) == wordsOnly + both)
        let hits = try await ChunkSearch(database: database).search("厂交货")
        #expect(hits.map(\.chunk) == both + wordsOnly)
        #expect(abs(hits[0].score - (1 / 60.0 + 1 / 60.0)) < 1e-9 || abs(hits[0].score - (1 / 61.0 + 1 / 60.0)) < 1e-9)
        #expect(hits[0].score > hits[1].score)
        await database.close()
    }

    @Test func hitsCarryTheirFilePageHeadingAndHiddenRuns() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let ids = try await add(
            ["The print run is 500 calendars."], file: "Brief.pdf", project: alpha, modified: 1_760_000_123.5, hiddenRuns: 2,
            page: 3, heading: "2. Printing", to: database)
        let hit = try #require(try await ChunkSearch(database: database).search("calendars").first)
        #expect(hit.chunk == ids[0])
        #expect(hit.project == alpha)
        #expect(hit.file.path == "/Projects/Brief.pdf")
        #expect(hit.page == 3)
        #expect(hit.heading == "2. Printing")
        #expect(hit.modified == Date(timeIntervalSince1970: 1_760_000_123.5))
        #expect(hit.text == "The print run is 500 calendars.")
        #expect(hit.fileHiddenRuns == 2)
        #expect(hit.score > 0)
        await database.close()
    }

    @Test func newestGivesTheChunksOfTheNewestFilesInOrder() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let old = try await add(["Old one.", "Old two."], file: "old.md", project: alpha, modified: 1_000, to: database)
        let new = try await add(["New one.", "New two."], file: "new.md", project: alpha, modified: 2_000, to: database)
        try await add(["Other project."], file: "other.md", project: beta, modified: 3_000, to: database)
        let search = ChunkSearch(database: database)
        #expect(try await search.newest(alpha, limit: 3).map(\.chunk) == new + [old[0]])
        #expect(try await search.newest(alpha, limit: 3).allSatisfy { $0.score == 0 && $0.project == alpha })
        #expect(try await search.newest(alpha, limit: 0).isEmpty)
        await database.close()
    }

    /// Scores for the sorting vote: above zero, higher for the better match, and only for
    /// projects that match.
    @Test func projectScoresFavorTheProjectThatMatches() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        try await add(["灯具采购合同已经签好，灯具下周到。"], file: "a.md", project: alpha, to: database)
        try await add(["印刷厂交货时间改到周五，灯具另算。"], file: "b.md", project: beta, to: database)
        try await add(["Nothing to see here."], file: "c.md", project: UUID(), to: database)
        let search = ChunkSearch(database: database)
        let scores = try await search.projectScores("灯具采购合同")
        #expect(Set(scores.keys) == [alpha, beta])
        #expect(scores.values.allSatisfy { $0 > 0 })
        #expect(try #require(scores[alpha]) > (try #require(scores[beta])))
        #expect(try await search.projectScores("灯具采购合同", among: [beta]).keys.sorted { $0.uuidString < $1.uuidString } == [beta])
        #expect(try await search.projectScores("灯具采购合同", among: []).isEmpty)
        #expect(try await search.projectScores("…").isEmpty)
        await database.close()
    }

    // MARK: Search terms

    /// A Chinese email shares no word with an English file. A term in English finds it.
    @Test func aTermFindsAChunkTheEmailsWordsMiss() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let plan = try await add(["The floor plan of the lobby, revision C. Lamps along the north wall."], file: "lobby.pdf", project: alpha, to: database)
        try await add(["Opening hours of the studio."], file: "hours.md", project: alpha, to: database)
        let search = ChunkSearch(database: database)
        let email = "大堂平面图\n大堂的平面图改好了吗？"
        #expect(try await search.search(ChunkSearch.Query(text: email, projects: [alpha])).isEmpty)
        let hits = try await search.search(ChunkSearch.Query(text: email, terms: ["平面图", "floor plan"], projects: [alpha]))
        #expect(hits.map(\.chunk) == plan)
        #expect(hits.allSatisfy { $0.matchedTerm })
        await database.close()
    }

    @Test func aTermOfSeveralWordsMatchesThemInARow() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let inARow = try await add(["The Floor Plan of the lobby."], file: "a.md", project: alpha, to: database)
        try await add(["A plan for the floor tiles."], file: "b.md", project: alpha, to: database)
        #expect(ChunkSearch.termWordQuery(["floor plan", "Floor  Plan", "lamp", "the", "x", "7"]) == #""floor plan" OR "lamp" OR "7""#)
        #expect(ChunkSearch.termWordQuery(["", "!!!", "of the"]) == nil)
        let hits = try await ChunkSearch(database: database).search(ChunkSearch.Query(text: "", terms: ["floor plan"], projects: [alpha]))
        #expect(hits.map(\.chunk) == inARow)
        await database.close()
    }

    /// A Chinese term of three characters or more matches as a substring, through the
    /// trigram table, wherever NLTokenizer cut the words.
    @Test func aChineseTermMatchesAsASubstring() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let ids = try await add(["请按新的平面图纸施工，灯具另算。"], file: "a.md", project: alpha, to: database)
        #expect(ChunkSearch.termTrigramQuery(["平面图", "图", "灯具", "plan", "平面 图", "平面图"]) == #""平面图""#)
        #expect(try await matches(ChunkSearch.termTrigramQuery(["平面图"]), in: "index_chunk_trigrams", database) == ids)
        let hits = try await ChunkSearch(database: database).search(ChunkSearch.Query(text: "", terms: ["平面图"], projects: [alpha]))
        #expect(hits.map(\.chunk) == ids)
        #expect(hits.first?.matchedTerm == true)
        await database.close()
    }

    /// Reciprocal rank fusion over the lists of the text and of the terms: a chunk both find
    /// goes first.
    @Test func chunksTheTextAndATermBothFindComeFirst() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let termOnly = try await add(["Floor plan of the lobby."], file: "a.md", project: alpha, to: database)
        let both = try await add(["Lamps in the lobby, as the floor plan shows them."], file: "b.md", project: alpha, to: database)
        let textOnly = try await add(["Lamps for the hall."], file: "c.md", project: alpha, to: database)
        let hits = try await ChunkSearch(database: database).search(ChunkSearch.Query(text: "lamps", terms: ["floor plan"], projects: [alpha]))
        #expect(hits.first?.chunk == both.first)
        #expect(Set(hits.map(\.chunk)) == Set(termOnly + both + textOnly))
        #expect(Set(hits.filter(\.matchedTerm).map(\.chunk)) == Set(termOnly + both))
        await database.close()
    }

    /// Each hit says which terms match it, each term alone as the lists of the terms search
    /// it: a phrase of its words in a row, and a Chinese term of three characters or more as
    /// a substring.
    @Test func eachHitSaysWhichTermsMatchIt() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let three = try await add(["The floor plan of the lobby, 平面图纸 revision C."], file: "a.md", project: alpha, to: database)
        let one = try await add(["A plan for the floor tiles of the lobby."], file: "b.md", project: alpha, to: database)
        let none = try await add(["Opening hours of the lobby."], file: "c.md", project: alpha, to: database)
        let search = ChunkSearch(database: database)
        let hits = try await search.search(ChunkSearch.Query(text: "opening hours", terms: ["floor plan", "平面图", "tiles", "hall", "Floor Plan"], projects: [alpha]))
        let terms = Dictionary(uniqueKeysWithValues: hits.map { ($0.chunk, $0.matchedTerms) })
        #expect(terms[three[0]] == ["floor plan", "平面图", "Floor Plan"])
        #expect(terms[one[0]] == ["tiles"])
        #expect(terms[none[0]] == [])
        #expect(hits.allSatisfy { $0.matchedTerm == !$0.matchedTerms.isEmpty })
        #expect(try await search.search(ChunkSearch.Query(text: "lobby", projects: [alpha])).allSatisfy { $0.matchedTerms.isEmpty && !$0.matchedTerm })
        await database.close()
    }

    @Test func termsOnlyKeepsWhatATermMatched() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let term = try await add(["Floor plan of the lobby."], file: "a.md", project: alpha, to: database)
        try await add(["Lamps for the hall."], file: "c.md", project: alpha, to: database)
        let search = ChunkSearch(database: database)
        #expect(try await search.search(ChunkSearch.Query(text: "lamps", terms: ["floor plan"], projects: [alpha], termsOnly: true)).map(\.chunk) == term)
        #expect(try await search.search(ChunkSearch.Query(text: "lamps", projects: [alpha], termsOnly: true)).isEmpty)
        #expect(try await search.search(ChunkSearch.Query(text: "lamps", terms: ["floor plan"], projects: [alpha], termsOnly: true, limit: 0)).isEmpty)
        await database.close()
    }

    /// A term from the model is data too: each is one quoted phrase, so nothing in it is
    /// FTS5 syntax, and the query is a bound value.
    @Test func hostileSearchTermsFindOnlyThemselves() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let calendars = try await add(["Calendars near the desk, 合同付款。"], file: "a.txt", project: alpha, to: database)
        try await add(["Unrelated text about lamps."], file: "b.txt", project: alpha, to: database)
        let hostile = [
            "\"", String(repeating: "\"", count: 3), "*", "calend*", "^start", "-minus", "NEAR(calendars desk)", "col:x", "words:calendars", "name:a",
            "AND", "OR", "NOT", "(", ")", "a\u{0}b", "合同\"付款", "\\", "'; DROP TABLE index_chunks; --", "{name words}: lamps",
        ]
        for term in hostile {
            for (table, query) in [("index_chunk_words", ChunkSearch.termWordQuery([term])), ("index_chunk_trigrams", ChunkSearch.termTrigramQuery([term]))] {
                let found = try await matches(query, in: table, database)
                #expect(found.isEmpty || found == calendars, "\(term) in \(table)")
            }
        }
        // As syntax, each of these would match: a prefix, NEAR, a column filter and a set of
        // columns.
        for term in ["calend*", "NEAR(calendars desk)", "name:a", "{name words}: lamps"] {
            #expect(try await matches(ChunkSearch.termWordQuery([term]), in: "index_chunk_words", database).isEmpty, "\(term)")
        }
        let search = ChunkSearch(database: database)
        for start in stride(from: 0, to: hostile.count, by: ChunkSearch.maximumTerms) {
            let terms = Array(hostile[start..<min(start + ChunkSearch.maximumTerms, hostile.count)])
            let found = try await search.search(ChunkSearch.Query(text: "", terms: terms, projects: [alpha], termsOnly: true))
            #expect(found.isEmpty || found.map(\.chunk) == calendars)
        }
        #expect(try await database.run("SELECT count(*) FROM index_chunks") == [[.integer(2)]])
        await database.close()
    }

    /// Without terms, a search gives the two lists of the text fused as before, worked out
    /// here from the tables themselves.
    @Test func withoutTermsTheSearchGivesWhatItGaveBefore() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        try await add(["灯具采购合同已经签好，灯具下周到。"], file: "a.md", project: alpha, to: database)
        try await add(["印刷厂交货时间改到周五，灯具另算。"], file: "b.md", project: alpha, to: database)
        try await add(["The lamps arrive on Friday.", "Lamps and calendars."], file: "c.md", project: alpha, to: database)
        try await add(["灯具采购 in the other project."], file: "d.md", project: beta, to: database)
        let search = ChunkSearch(database: database)
        for text in ["灯具采购合同", "lamps calendars", "交货 灯具 lamps", "周五"] {
            var scores: [Int64: Double] = [:]
            for (table, query) in [("index_chunk_words", ChunkSearch.wordQuery(text)), ("index_chunk_trigrams", ChunkSearch.trigramQuery(text))] {
                guard let query else { continue }
                let rows = try await database.run(
                    "SELECT \(table).rowid FROM \(table) JOIN index_chunks c ON c.id = \(table).rowid WHERE \(table) MATCH ? AND c.project = ? ORDER BY bm25(\(table)) LIMIT 50",
                    [.text(query), .text(alpha.uuidString)])
                for (rank, row) in rows.enumerated() {
                    scores[row[0].integer!, default: 0] += 1 / (60 + Double(rank))
                }
            }
            let expected = scores.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.prefix(6)
            let hits = try await search.search(ChunkSearch.Query(text: text, projects: [alpha]))
            #expect(hits.map(\.chunk) == expected.map(\.key), "\(text)")
            #expect(zip(hits.map(\.score), expected.map(\.value)).allSatisfy { abs($0 - $1) < 1e-12 }, "\(text)")
            #expect(!hits.contains { $0.matchedTerm })
            #expect(try await search.search(text, in: [alpha]) == hits)
        }
        await database.close()
    }

    @Test func termSearchStaysInTheProjectsItIsGiven() async throws {
        defer { cleanUp() }
        let database = try await ProjectsDatabase.open(in: storage)
        let inAlpha = try await add(["Floor plan of the lobby."], file: "a.md", project: alpha, to: database)
        let inBeta = try await add(["Floor plan of the hall."], file: "b.md", project: beta, to: database)
        let search = ChunkSearch(database: database)
        func found(_ projects: [UUID]?) async throws -> Set<Int64> {
            Set(try await search.search(ChunkSearch.Query(text: "", terms: ["floor plan"], projects: projects, termsOnly: true)).map(\.chunk))
        }
        #expect(try await found([alpha]) == Set(inAlpha))
        #expect(try await found([beta]) == Set(inBeta))
        #expect(try await found(nil) == Set(inAlpha + inBeta))
        #expect(try await found([]).isEmpty)
        #expect(try await found([UUID()]).isEmpty)
        await database.close()
    }
}
