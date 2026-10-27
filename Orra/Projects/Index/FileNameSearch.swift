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
///   constant.
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

    /// The best `limit` files whose names or folders match `text`, in `projects` or in all
    /// of them when nil. Off the main actor, since NLTokenizer and the full text queries
    /// take a while.
    @concurrent
    func search(_ text: String, in projects: [UUID]? = nil, limit: Int = 20) async throws -> [Hit] {
        guard projects?.isEmpty != true, limit > 0 else { return [] }
        let queries = [("index_file_names", ChunkSearch.wordQuery(text)), ("index_file_name_trigrams", ChunkSearch.trigramQuery(text))]
        var lists: [[Int64]] = []
        for case let (table, query?) in queries {
            var parameters: [ProjectsDatabase.Value] = [.text(query)]
            var sql = "SELECT \(table).rowid FROM \(table) JOIN index_files f ON f.id = \(table).rowid WHERE \(table) MATCH ?1"
            if let projects {
                parameters.append(.text(Self.json(projects.map { "\"\($0.uuidString)\"" })))
                sql += " AND f.project IN (SELECT value FROM json_each(?2))"
            }
            sql += " ORDER BY bm25(\(table), \(Self.nameWeight), \(Self.folderWeight)) LIMIT \(ChunkSearch.listLength)"
            lists.append(try await database.run(sql, parameters).compactMap { $0.first?.integer })
        }
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (rank, file) in list.enumerated() {
                scores[file, default: 0] += 1 / (ChunkSearch.fusionOffset + Double(rank))
            }
        }
        let best = scores.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.prefix(limit)
        guard !best.isEmpty else { return [] }
        let rows = try await database.run(
            "SELECT id, project, path, size, modified, skip FROM index_files WHERE id IN (SELECT value FROM json_each(?))",
            [.text(Self.json(best.map { String($0.key) }))])
        var hits: [Int64: Hit] = [:]
        for row in rows where row.count == 6 {
            guard let file = row[0].integer, let project = row[1].text.flatMap(UUID.init(uuidString:)), let path = row[2].text,
                  let size = row[3].integer, let modified = row[4].real else { continue }
            let skip = row[5].text.map { FileSkipReason(rawValue: $0) ?? .unsupportedFormat }
            hits[file] = Hit(
                file: file, project: project, url: URL(fileURLWithPath: path), size: size,
                modified: Date(timeIntervalSince1970: modified), skip: skip, score: 0)
        }
        return best.compactMap { file, score in
            hits[file].map { hit in
                var hit = hit
                hit.score = score
                return hit
            }
        }
    }

    /// A JSON array of values written as JSON already, for json_each.
    private static func json(_ values: [String]) -> String {
        "[" + values.joined(separator: ",") + "]"
    }
}
