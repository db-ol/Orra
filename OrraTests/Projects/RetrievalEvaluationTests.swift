import Foundation
import NaturalLanguage
import Testing
@testable import Orra

/// Measures which passages of project files Explain gives the model for the labeled mails of
/// the synthetic Projects set and its retrieval supplement, before, as 0.6.0 chose them
/// without terms and with every passage of a file, and after, with the terms of the real
/// cleanup model, at most `ExplainService.perFileChunks` passages of a file before the
/// passages of other files, and the files of other projects, see
/// ExplainService.files(for:project:known:query:warnings:lookups:). It also picks with each
/// of the two changes alone. Only when asked for, never in CI, and in a Release build:
///
///     TEST_RUNNER_ORRA_PROJECTS_RETRIEVAL=~/projects/orra-project/bench/projects-testset \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES=<work address>,<home address> \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_NAME=<name> \
///     TEST_RUNNER_ORRA_PROJECTS_RETRIEVAL_OUT=<folder> \
///     xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/RetrievalEvaluationTests
///
/// The set's folder holds the supplement in retrieval/: folders/<project>/ with more files
/// for each project, mail.jsonl with more mails, and labels.jsonl, one line a mail with the
/// files that answer it, as paths in the set's folder, and its kinds. docs/release-gate.md
/// describes them. FolderIndex indexes each project with two folders, its folder of the set
/// and its folder of the supplement, and both runs use that one index.
///
/// For each labeled mail it builds the email and the people the user knows as
/// ExplainEvaluationTests does, finds its warnings with the checks of ExplainService, and
/// picks the passages a prompt would hold before its budget trims any, see
/// ExplainPrompt.excerpts. It writes retrieval.jsonl, one row a mail, and retrieval.md with
/// the tables and the bar, and prints counts only.
///
/// TEST_RUNNER_ORRA_PROJECTS_RETRIEVAL_TERMS names a retrieval-terms.jsonl of an earlier
/// run, whose terms it takes without the model. TEST_RUNNER_ORRA_PROJECTS_RETRIEVAL_SWEEP=1
/// picks the passages again with each rule of `variants` for other projects' passages,
/// without the model, and gives each rule's line of the bar.
/// TEST_RUNNER_ORRA_PROJECTS_RETRIEVAL_EXPLAIN, such as zh,en, also explains the mails of the
/// kinds other-project, needs-project and negative with the real model in those languages,
/// as the app does, with the draft written apart from other projects' passages, and once
/// more with one request that writes the draft from them too, as before, to time both. It
/// counts the drafts that hold a value, a name or an address that only another project's
/// passage holds, or a run of 6 words or 10 Chinese characters of one.
///
/// The set and its supplement stay outside the repository, and so do the results.
@Suite(.serialized, .enabled(if: RetrievalSet.folder != nil && !RetrievalSet.ownAddresses.isEmpty))
@MainActor
struct RetrievalEvaluationTests {
    private nonisolated static let today = ISO8601DateFormatter().date(from: "2026-10-18T20:00:00+08:00")!
    private nonisolated static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    @Test func measureTheSelection() async throws {
        let root = try #require(RetrievalSet.folder)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: ((environment["ORRA_PROJECTS_RETRIEVAL_OUT"] ?? NSTemporaryDirectory()) as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let supplement = root.appendingPathComponent("retrieval", isDirectory: true)
        let mails = try Self.mails(root.appendingPathComponent("mail.jsonl")) + Self.mails(supplement.appendingPathComponent("mail.jsonl"))
        let byID = Dictionary(mails.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byMessageID = Dictionary(mails.map { (Self.bare($0.message_id), $0) }, uniquingKeysWith: { first, _ in first })
        let labels = try String(contentsOf: supplement.appendingPathComponent("labels.jsonl"), encoding: .utf8)
            .split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
            .map { try JSONDecoder().decode(Label.self, from: Data($0.utf8)) }
        try #require(!labels.isEmpty)
        let setProjects = try JSONDecoder().decode([SetProject].self, from: Data(contentsOf: root.appendingPathComponent("projects/projects.json")))
        let ids = Dictionary(uniqueKeysWithValues: setProjects.enumerated().map { index, project in
            (project.slug, UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!)
        })
        let slugs = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
        let projects = setProjects.map { project in
            ExplainService.Project(id: ids[project.slug]!, name: project.name, description: project.description, people: project.people.map(Self.person), domains: project.domains)
        }

        // The index, with each project's folder of the set and of the supplement. It holds the
        // set's text, so it goes whichever way the run ends.
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("RetrievalEvaluationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try await ProjectsDatabase.open(in: ProjectsStorage(root: storageRoot))
        let index = FolderIndex(database: database, isDictating: { false }, watch: { _, _, _ in {} })
        let indexStarted = ContinuousClock.now
        var projectFiles: [String: URL] = [:]
        for project in setProjects {
            var folders = [root.appendingPathComponent(project.folder, isDirectory: true)]
            let more = supplement.appendingPathComponent("folders/\(project.slug)", isDirectory: true)
            if FileManager.default.fileExists(atPath: more.path) {
                folders.append(more)
            }
            for folder in folders {
                for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where projectFiles[name] == nil {
                    projectFiles[name] = folder.appendingPathComponent(name)
                }
            }
            index.start(project: ids[project.slug]!, folders: folders)
        }
        await index.waitUntilIdle()
        let indexTime = indexStarted.duration(to: .now)
        index.stopAll()
        let files = try await database.run("SELECT count(*) FROM index_files WHERE skip IS NULL").first?.first?.integer ?? 0
        let chunks = try await database.run("SELECT count(*) FROM index_chunks").first?.first?.integer ?? 0
        let search = ChunkSearch(database: database)
        let realRoot = root.resolvingSymlinksInPath().path + "/"
        func relative(_ url: URL) -> String {
            let path = url.path
            return path.hasPrefix(realRoot) ? String(path.dropFirst(realRoot.count)) : path
        }

        // The terms, from an earlier run or from the model through the queue as the app runs it.
        let termsFile = environment["ORRA_PROJECTS_RETRIEVAL_TERMS"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var savedTerms: [String: TermsRun] = [:]
        if let termsFile {
            for line in try String(contentsOf: termsFile, encoding: .utf8).split(separator: "\n") where !line.allSatisfy(\.isWhitespace) {
                let run = try JSONDecoder().decode(TermsRun.self, from: Data(line.utf8))
                savedTerms[run.id] = run
            }
        }
        var engine: CleanupEngine?
        var queue: ProjectsModelQueue?
        var counter: ProjectsTokenCounter?
        let explainLanguages = (environment["ORRA_PROJECTS_RETRIEVAL_EXPLAIN"] ?? "").split(separator: ",").compactMap { ProjectsLanguage(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        if termsFile == nil || !explainLanguages.isEmpty {
            let modelFolder = try #require(RewriteTestModel.folder, "no cleanup model on this Mac")
            let live = CleanupEngine.live(RewriteEngine(), gate: ModelGate())
            try await live.load(modelFolder)
            engine = live
            counter = try await ProjectsTokenCounter.reading(modelFolder)
            queue = ProjectsModelQueue(environment: ProjectsModelEnvironment(
                startJob: live.startJob, readSlice: live.readSlice, writeBurst: live.writeBurst, endJob: live.endJob,
                isDictating: { false }, captionsOn: { false }, memoryPressure: { .normal }, voiceLoaded: { false },
                physicalMemory: ProcessInfo.processInfo.physicalMemory, waitUntilLoaded: { true }, holdModel: {}, releaseModel: {},
                sleep: { try await Task.sleep(for: $0) }))
        }
        func askModel(_ email: ExplainService.Email) async throws -> TermsRun {
            let queue = try #require(queue)
            let prompt = SearchTermsPrompt(searchText: await ExplainService.searchText(email), attachmentNames: email.attachments.map(\.name))
            let started = ContinuousClock.now
            do {
                let written = try await queue.run(ProjectsModelRequest(prompt: prompt.text, maximumTokens: SearchTermsPrompt.maximumTokens, priority: .user))
                let seconds = started.duration(to: .now) / .seconds(1)
                let terms = SearchTermsPrompt.terms(written)
                let timedOut = seconds > SearchTerms.timeLimit / .seconds(1)
                return TermsRun(
                    id: "", terms: timedOut ? nil : terms, seconds: seconds,
                    fallback: timedOut ? "time limit" : (terms == nil ? "no terms" : nil),
                    promptTokens: counter?.count(prompt.text), answerTokens: counter?.count(written))
            } catch {
                return TermsRun(id: "", terms: nil, seconds: started.duration(to: .now) / .seconds(1), fallback: "failed", promptTokens: nil, answerTokens: nil)
            }
        }
        if termsFile == nil, let first = labels.first.flatMap({ byID[$0.id] }) {
            // A warm up, so no measured run pays for the first one.
            _ = try await askModel(Self.email(first, project: nil))
        }

        let searchTimes = SearchTimes()
        let rankings = Rankings()
        func lookups(_ terms: [String]?) -> ExplainService.Lookups {
            ExplainService.Lookups(
                known: { _ in ExplainService.Known() }, thread: { _ in [] }, projectMail: { _ in [] },
                search: { query in
                    let started = ContinuousClock.now
                    defer { searchTimes.add(started.duration(to: .now) / .seconds(1)) }
                    let hits = try await search.search(query)
                    // The ranking of all projects for an email in a project, for a reader.
                    if !query.termsOnly, (query.projects?.count ?? 0) > 1 {
                        rankings.keep(hits)
                    }
                    return hits
                },
                newest: { project, limit in try await search.newest(project, limit: limit) },
                files: { project in
                    try await database.run(
                        "SELECT f.path, f.modified, (SELECT c.text FROM index_chunks c WHERE c.file = f.id ORDER BY c.id LIMIT 1) FROM index_files f WHERE f.project = ? AND f.skip IS NULL",
                        [.text(project.uuidString)]
                    ).compactMap { row in
                        guard row.count == 3, let path = row[0].text, let modified = row[1].real else { return nil }
                        return FileVersions.File(url: URL(fileURLWithPath: path), modified: Date(timeIntervalSince1970: modified), head: row[2].text ?? "")
                    }
                },
                terms: { _ in terms })
        }
        /// The passages a prompt holds before its budget, see ExplainPrompt.excerpts, or with
        /// `replacing` as round 2 held them: other projects' passages in place of the project's
        /// weakest, and the newest files filling up to three passages counting them.
        func picked(_ found: ExplainService.Files, replacing: Bool = false) -> [Picked] {
            let chunk = { (hit: ChunkSearch.Hit) in TextChunker.Chunk(file: hit.file, page: hit.page, modified: hit.modified, heading: hit.heading, text: hit.text) }
            let others = found.others.map { ExplainPrompt.OtherChunk(chunk: chunk($0), project: $0.project, projectName: "") }
            var (own, other) = ExplainPrompt.excerpts(chunks: found.hits.map(chunk), newest: found.newest.map(chunk), others: others)
            if replacing {
                own = Array(found.hits.map(chunk).prefix(ExplainPrompt.chunkLimit - other.count))
                for newest in found.newest.map(chunk) where own.count + other.count < ExplainPrompt.fillUpTo && !own.contains(where: { $0.file == newest.file }) {
                    own.append(newest)
                }
            }
            let terms = Dictionary((found.hits + found.others).map { ($0.file.path + "\u{0}" + $0.text, $0.matchedTerms) }, uniquingKeysWith: { first, _ in first })
            return own.map { Picked(path: relative($0.file), project: nil, text: $0.text, terms: terms[$0.file.path + "\u{0}" + $0.text] ?? []) }
                + other.map { Picked(path: relative($0.chunk.file), project: slugs[$0.project] ?? "?", text: $0.chunk.text, terms: terms[$0.chunk.file.path + "\u{0}" + $0.chunk.text] ?? []) }
        }
        let sweep = environment["ORRA_PROJECTS_RETRIEVAL_SWEEP"] == "1"

        var rows: [Row] = []
        var sweeps: [String: [String: [Picked]]] = [:]
        var termRuns: [TermsRun] = []
        for label in labels {
            let mail = try #require(byID[label.id], "no mail \(label.id)")
            let project = mail.labels.project.flatMap { ids[$0] }
            var email = Self.email(mail, project: project)
            email.attachments = await Self.attachments(of: mail, files: projectFiles)
            let known = Self.known(before: email, mails: mails, projects: projects)
            let rules = await ExplainService.ruleWarnings(email, known: known)
            let attachments = await ExplainService.attachmentWarnings(email, known: known)
            let warnings = await ExplainService.retrievalWarnings(email, rules: rules, attachments: attachments)
            let query = await ExplainService.searchText(email)
            let projectValue = projects.first { $0.id == project }
            searchTimes.reset()
            // 0.6.0's selection: no terms, and every passage of a file.
            let before = try await ExplainService.files(for: email, project: projectValue, known: known, query: query, warnings: warnings, lookups: lookups(nil), perFileChunks: nil)
            let beforeSearches = searchTimes.take()
            let beforeCapped = try await ExplainService.files(for: email, project: projectValue, known: known, query: query, warnings: warnings, lookups: lookups(nil))
            var run: TermsRun
            if let saved = savedTerms[label.id] {
                run = saved
            } else if termsFile == nil {
                run = try await askModel(email)
            } else {
                run = TermsRun(id: label.id, terms: nil, seconds: 0, fallback: "not in the terms file", promptTokens: nil, answerTokens: nil)
            }
            run.id = label.id
            termRuns.append(run)
            searchTimes.reset()
            _ = rankings.take()
            let after = try await ExplainService.files(for: email, project: projectValue, known: known, query: query, warnings: warnings, lookups: lookups(run.terms))
            let afterSearches = searchTimes.take()
            let ranking = rankings.take().prefix(10).map { hit in
                Picked(path: relative(hit.file), project: hit.project == project ? nil : slugs[hit.project] ?? "?", text: hit.text, terms: hit.matchedTerms)
            }
            let afterUncapped = try await ExplainService.files(for: email, project: projectValue, known: known, query: query, warnings: warnings, lookups: lookups(run.terms), perFileChunks: nil)
            for variant in sweep ? Self.variants : [] {
                let swept = try await ExplainService.files(for: email, project: projectValue, known: known, query: query, warnings: warnings, lookups: lookups(run.terms), rule: variant.rule)
                sweeps[variant.name, default: [:]][label.id] = picked(swept, replacing: variant.replacing)
            }
            _ = searchTimes.take()
            rows.append(Row(
                id: label.id, kinds: label.kind, project: mail.labels.project ?? "none", relevant: label.relevant,
                before: picked(before), after: picked(after), beforeCapped: picked(beforeCapped), afterUncapped: picked(afterUncapped),
                otherProjectsBefore: before.otherProjects.rawValue, otherProjectsAfter: after.otherProjects.rawValue,
                warnings: ProjectsWarning.allCases.filter(warnings.contains).map(\.rawValue),
                terms: run.terms?.count ?? 0, termsValid: run.terms != nil, termsSeconds: run.seconds, termsFallback: run.fallback,
                searchSeconds: beforeSearches + afterSearches, ranking: ranking.isEmpty ? nil : Array(ranking)))
        }

        // The rows and the report, outside the repository, before the leak check, so a run
        // that fails there keeps them.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n").appending("\n")
            .write(to: out.appendingPathComponent("retrieval.jsonl"), atomically: true, encoding: .utf8)
        if termsFile == nil {
            try termRuns.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n").appending("\n")
                .write(to: out.appendingPathComponent("retrieval-terms.jsonl"), atomically: true, encoding: .utf8)
        }
        if !sweeps.isEmpty {
            // Each rule's passages for each mail, for a reader.
            var lines: [String] = []
            for variant in Self.variants {
                for row in rows {
                    let picked = sweeps[variant.name]?[row.id] ?? []
                    lines.append(String(decoding: try encoder.encode(SweptRow(rule: variant.name, id: row.id, picked: picked)), as: UTF8.self))
                }
            }
            try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("retrieval-sweep.jsonl"), atomically: true, encoding: .utf8)
        }
        func writeReport(_ leaks: [Leak]) throws {
            let report = Self.report(rows, sweeps: sweeps, leaks: leaks, files: Int(files), chunks: Int(chunks), indexTime: indexTime, measuredTerms: termsFile == nil)
            try report.write(to: out.appendingPathComponent("retrieval.md"), atomically: true, encoding: .utf8)
        }
        try writeReport([])

        // The leak check: explanations of the mails that may read other projects' files, as
        // the app makes them, then with one request as before, each timed whole.
        var leaks: [Leak] = []
        if !explainLanguages.isEmpty, let queue, let counter {
            let requests = Requests()
            for language in explainLanguages {
                func service(draftApart: Bool) -> ExplainService {
                    ExplainService(
                        lookups: Self.explainLookups(mails: mails, byMessageID: byMessageID, projects: projects, ids: ids, lookups: lookups(nil), termsFor: { id in savedTerms[id]?.terms ?? termRuns.first { $0.id == id }?.terms }),
                        run: { request in
                            requests.add()
                            return try await queue.run(request)
                        },
                        loadTokenCounter: { counter.count },
                        save: { _ in },
                        language: language,
                        timeZone: Self.timeZone,
                        now: { Self.today },
                        draftApart: draftApart)
                }
                let apart = service(draftApart: true)
                let together = service(draftApart: false)
                for row in rows where !Set(row.kinds).isDisjoint(with: ["other-project", "needs-project", "negative"]) {
                    let mail = try #require(byID[row.id])
                    var email = Self.email(mail, project: mail.labels.project.flatMap { ids[$0] })
                    email.attachments = await Self.attachments(of: mail, files: projectFiles)
                    for (draftApart, service) in [(true, apart), (false, together)] {
                        requests.reset()
                        let started = ContinuousClock.now
                        let explanation = try await service.explain(email)
                        var leak = Self.leak(row.id, language: language, explanation: explanation)
                        leak.draftApart = draftApart
                        leak.seconds = started.duration(to: .now) / .seconds(1)
                        leak.requests = requests.count
                        let others = explanation.sources.filter { ExplainPrompt.isOtherFileSource($0.key) }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                        leak.otherPassages = others.count
                        leak.otherFiles = others.compactMap { _, source in
                            guard case .file(let chunk, _) = source else { return nil }
                            return relative(chunk.file)
                        }
                        leaks.append(leak)
                    }
                }
            }
        }
        if let engine {
            await engine.unload()
        }
        await database.close()

        if !leaks.isEmpty {
            try leaks.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n").appending("\n")
                .write(to: out.appendingPathComponent("retrieval-leaks.jsonl"), atomically: true, encoding: .utf8)
            try writeReport(leaks)
        }
        // Counts only.
        print("Retrieval: \(rows.count) mails, \(files) files in \(chunks) chunks indexed in \(Self.seconds(indexTime)), \(rows.filter(\.termsValid).count) with terms, \(leaks.filter { $0.draftApart && !$0.found.isEmpty }.count) drafts with another project's data. Rows in retrieval.jsonl, tables in retrieval.md.")
        #expect(rows.count == labels.count)
    }

    // MARK: The set

    private struct SetMail: Decodable {
        struct Attachment: Decodable {
            let name: String
            let type: String
        }

        struct Labels: Decodable {
            let project: String?
        }

        let id: String
        let message_id: String
        let in_reply_to: String?
        let references: [String]?
        let thread: String?
        let date: String
        let from: String
        let to: [String]
        let cc: [String]?
        let subject: String
        let body: String
        let attachments: [Attachment]?
        let labels: Labels
    }

    private struct SetProject: Decodable {
        let slug: String
        let name: String
        let description: String
        let folder: String
        let people: [String]
        let domains: [String]
    }

    /// A labeled mail: the files that answer it or support it, as paths in the set's folder,
    /// and its kinds.
    private struct Label: Decodable {
        let id: String
        let relevant: [String]
        let kind: [String]
    }

    /// The terms of one mail, with how they came.
    private struct TermsRun: Codable {
        var id: String
        var terms: [String]?
        var seconds: Double
        /// Why there are none: no terms, a failed job, the time limit.
        var fallback: String?
        var promptTokens: Int?
        var answerTokens: Int?
    }

    /// A passage of the selection: its file in the set's folder, the project of another
    /// project's passage, and the terms that match it, which say why it is there.
    private struct Picked: Codable {
        var path: String
        var project: String?
        var text: String
        var terms: [String] = []

        enum CodingKeys: String, CodingKey {
            case path, project, terms
        }

        init(path: String, project: String?, text: String, terms: [String] = []) {
            self.path = path
            self.project = project
            self.text = text
            self.terms = terms
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            project = try container.decodeIfPresent(String.self, forKey: .project)
            terms = try container.decodeIfPresent([String].self, forKey: .terms) ?? []
            text = ""
        }
    }

    private struct Row: Codable {
        var id: String
        var kinds: [String]
        var project: String
        var relevant: [String]
        /// 0.6.0's selection: without terms, and with every passage of a file.
        var before: [Picked]
        /// With the terms and at most `ExplainService.perFileChunks` passages of a file.
        var after: [Picked]
        /// Without terms, with the cap of a file's passages.
        var beforeCapped: [Picked]
        /// With the terms, without the cap.
        var afterUncapped: [Picked]
        var otherProjectsBefore: String
        var otherProjectsAfter: String
        var warnings: [String]
        var terms: Int
        var termsValid: Bool
        var termsSeconds: Double
        var termsFallback: String?
        var searchSeconds: [Double]
        /// The first ten of the ranking of all projects for an email in a project, which
        /// decides whether other projects' passages come in, with the project of each passage
        /// of another project and the terms that match each.
        var ranking: [Picked]? = nil

        func recall(_ picked: [Picked]) -> Double {
            guard !relevant.isEmpty else { return 0 }
            let paths = Set(picked.map(\.path))
            return Double(relevant.filter(paths.contains).count) / Double(relevant.count)
        }

        func hit(_ picked: [Picked]) -> Bool {
            !Set(picked.map(\.path)).isDisjoint(with: relevant)
        }

        /// The rank of the first relevant passage, from 1.
        func firstRank(_ picked: [Picked]) -> Int? {
            picked.firstIndex { relevant.contains($0.path) }.map { $0 + 1 }
        }
    }

    /// What a draft holds that only another project's passages hold, and how the
    /// explanation was made.
    private struct Leak: Codable {
        var id: String
        var language: String
        var draft: String?
        var found: [String]
        /// Whether the draft came from a request without other projects' passages, as the
        /// app writes it, or from the one request of the explanation, as before.
        var draftApart = true
        /// The whole explanation, with the search, the checks and every request.
        var seconds: Double = 0
        /// The requests to the model, a second one for the rest of a repeating answer too.
        var requests = 0
        /// The passages of other projects in the explanation's prompt.
        var otherPassages = 0
        /// Their files, as paths in the set's folder.
        var otherFiles: [String] = []
    }

    /// Counts the requests of one explanation.
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func add() {
            lock.withLock { value += 1 }
        }

        func reset() {
            lock.withLock { value = 0 }
        }

        var count: Int {
            lock.withLock { value }
        }
    }

    /// The last ranking of all projects that a search gave.
    private final class Rankings: @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [ChunkSearch.Hit] = []

        func keep(_ hits: [ChunkSearch.Hit]) {
            lock.withLock { self.hits = hits }
        }

        func take() -> [ChunkSearch.Hit] {
            lock.withLock {
                defer { hits = [] }
                return hits
            }
        }
    }

    private final class SearchTimes: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []

        func add(_ time: Double) {
            lock.withLock { times.append(time) }
        }

        func reset() {
            lock.withLock { times = [] }
        }

        func take() -> [Double] {
            lock.withLock {
                defer { times = [] }
                return times
            }
        }
    }

    private nonisolated static func mails(_ url: URL) throws -> [SetMail] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
            .map { try JSONDecoder().decode(SetMail.self, from: Data($0.utf8)) }
    }

    private nonisolated static func bare(_ messageID: String) -> String {
        messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    private nonisolated static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    private nonisolated static func person(_ value: String) -> ExplainPrompt.Person {
        let parsed = MailAddressHeader.list(value).first
        return ExplainPrompt.Person(name: parsed?.name ?? "", address: parsed?.address ?? value)
    }

    private nonisolated static func isOwn(_ value: String) -> Bool {
        ProjectsAddress.normalized(person(value).address).map(RetrievalSet.ownAddresses.contains) ?? false
    }

    /// The email as the store keeps it for the app: its own text without the quoted history.
    private nonisolated static func email(_ mail: SetMail, project: UUID?) -> ExplainService.Email {
        ExplainService.Email(
            messageID: bare(mail.message_id), date: date(mail.date), sender: person(mail.from),
            to: mail.to.map(person), cc: (mail.cc ?? []).map(person), subject: mail.subject,
            attachments: (mail.attachments ?? []).map { MailAttachment(name: $0.name, type: $0.type, state: .otherType) },
            text: QuotedHistory(splitting: mail.body, subject: mail.subject).ownText, visibleText: mail.body, project: project)
    }

    /// The user and the people the user wrote with in mail dated before this one.
    private nonisolated static func known(before email: ExplainService.Email, mails: [SetMail], projects: [ExplainService.Project]) -> ExplainService.Known {
        let earlier = mails.filter { date($0.date) < email.date }
        var correspondents: [SenderChecks.Person] = []
        var seen: Set<String> = []
        for mail in earlier {
            for value in [mail.from] + mail.to + (mail.cc ?? []) {
                let person = person(value)
                guard let address = ProjectsAddress.normalized(person.address), !RetrievalSet.ownAddresses.contains(address), seen.insert(address).inserted else { continue }
                correspondents.append(SenderChecks.Person(name: person.name, address: address))
            }
        }
        let sent = earlier.filter { isOwn($0.from) }.map(\.body)
        return ExplainService.Known(ownName: RetrievalSet.ownName, ownAddresses: RetrievalSet.ownAddresses, projects: projects, correspondents: correspondents, sentTexts: sent)
    }

    /// The mail's attachments as the scan reads them: with the file of the project folders
    /// that has the attachment's name, else as a name and a type.
    private nonisolated static func attachments(of mail: SetMail, files: [String: URL]) async -> [MailAttachment] {
        let attached = (mail.attachments ?? []).map { attachment in
            let data = files[attachment.name].flatMap { try? Data(contentsOf: $0) }
            return AttachedFiles.File(name: attachment.name, type: attachment.type, data: data ?? Data())
        }
        return await MailAttachment.read(AttachedFiles.parts(attached), modified: date(mail.date))
    }

    /// The lookups of a whole explanation for the leak check: the set's threads by their
    /// ids and links, no other mail of the project, and the terms of this run.
    private static func explainLookups(
        mails: [SetMail], byMessageID: [String: SetMail], projects: [ExplainService.Project], ids: [String: UUID],
        lookups: ExplainService.Lookups, termsFor: @escaping @MainActor (String) -> [String]?
    ) -> ExplainService.Lookups {
        var terms: [String: [String]?] = [:]
        for mail in mails {
            terms[bare(mail.message_id)] = termsFor(mail.id)
        }
        let fixed = terms
        var explain = lookups
        explain.known = { email in known(before: email, mails: mails, projects: projects) }
        explain.thread = { email in
            guard let mail = byMessageID[email.messageID] else { return [] }
            var found: [String: SetMail] = [:]
            if let thread = mail.thread {
                for other in mails where other.thread == thread && other.id != mail.id {
                    found[other.id] = other
                }
            }
            return found.values.sorted { date($0.date) < date($1.date) }.map { other in
                ExplainPrompt.Mail(
                    messageID: bare(other.message_id), date: date(other.date), sender: person(other.from), to: other.to.map(person),
                    cc: (other.cc ?? []).map(person), subject: other.subject, attachmentNames: (other.attachments ?? []).map(\.name),
                    text: QuotedHistory(splitting: other.body, subject: other.subject).ownText)
            }
        }
        explain.terms = { email in fixed[email.messageID] ?? nil }
        return explain
    }

    // MARK: The leak check

    /// What a checked draft holds that only another project's passages hold: an amount, a
    /// code, an address, a personal name, or a run of 6 words or 10 Chinese characters, none
    /// of which the email or the project's own sources hold.
    private static func leak(_ id: String, language: ProjectsLanguage, explanation: Explanation) -> Leak {
        guard case .checked(let result) = explanation.draft, let draft = result.draft, let check = explanation.draftCheck,
              let others = check.otherProjectTexts, !others.isEmpty else {
            return Leak(id: id, language: language.rawValue, draft: nil, found: [])
        }
        let other = others.joined(separator: "\n\n").precomposedStringWithCompatibilityMapping
        let known = ([check.incomingText] + check.sourceTexts).joined(separator: "\n\n").precomposedStringWithCompatibilityMapping
        let text = draft.precomposedStringWithCompatibilityMapping
        var found: [String] = []
        // The user, the recipients and the project's people are no leak, nor is the user's
        // name as the user's addresses spell it, such as Lin Zhou for lin.zhou@.
        let people = check.own + check.recipients + check.projectPeople
        let allowedForms = Set(people.flatMap { SenderChecks.nameForms($0.name) })
        let allowedAddresses = Set(people.map { $0.address.lowercased() })
        let localParts = check.own.compactMap { person in
            person.address.lowercased().split(separator: "@").first.map { Set($0.split(whereSeparator: { ".-_".contains($0) }).map(String.init)) }
        }
        func isAllowed(_ name: String) -> Bool {
            if SenderChecks.nameForms(name).contains(where: allowedForms.contains) { return true }
            let words = Set(name.lowercased().split(separator: " ").map(String.init))
            return words.count >= 2 && localParts.contains { words.isSubset(of: $0) }
        }
        /// A number that only numbers a line of a list, such as 2. or 3、
        func isListMarker(_ range: Range<String.Index>) -> Bool {
            let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            guard text[lineStart..<range.lowerBound].allSatisfy(\.isWhitespace), range.upperBound < text.endIndex else { return false }
            return ".、)）".contains(text[range.upperBound])
        }
        let values = { (text: String) in Set(OutputChecks.numbers(in: text, skippingDatesAndCodes: false).filter { $0.isAmount || $0.isScore }.map(\.value)) }
        for number in OutputChecks.numbers(in: text) where values(other).contains(number.value) && !values(known).contains(number.value) && !isListMarker(number.range) {
            found.append("value " + String(text[number.range]))
        }
        let codes = { (text: String) in Set(OutputChecks.codes(in: text).map { OutputChecks.codeValue(text[$0]) }) }
        for code in OutputChecks.codes(in: text) where codes(other).contains(OutputChecks.codeValue(text[code])) && !codes(known).contains(OutputChecks.codeValue(text[code])) {
            found.append("code " + String(text[code]))
        }
        let addresses = { (text: String) in
            Set(OutputChecks.mailAddress.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { text[$0].lowercased() } })
        }
        for address in addresses(text) where addresses(other).contains(address) && !addresses(known).contains(address) && !allowedAddresses.contains(address) {
            found.append("address " + address)
        }
        for name in names(in: other) where text.contains(name) && !known.contains(name) && !isAllowed(name) {
            found.append("name " + name)
        }
        let shared = runs(in: other).subtracting(runs(in: known))
        for run in runs(in: text) where shared.contains(run) {
            found.append("run " + run)
            break
        }
        return Leak(id: id, language: language.rawValue, draft: draft, found: found)
    }

    /// Personal names: Chinese ones by the rules of ScreenNames, Latin ones from the tagger.
    private static func names(in text: String) -> [String] {
        var names = ScreenNames.hanTerms(in: text, common: .none).filter { $0.2 == .name }.map(\.0)
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, text[range].contains(" ") {
                names.append(String(text[range]))
            }
            return true
        }
        return names
    }

    /// The runs of 6 words or 10 Chinese characters in the text, in matching form, a word
    /// counting as one and two thirds characters in a mixed run.
    private static func runs(in text: String) -> Set<String> {
        var words: [(String, Int)] = []
        var current = ""
        for character in SortingText.matchingForm(text) {
            if character.unicodeScalars.allSatisfy(ChineseText.isHan) {
                if !current.isEmpty { words.append((current, 5)); current = "" }
                words.append((String(character), 3))
            } else if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append((current, 5))
                current = ""
            }
        }
        if !current.isEmpty { words.append((current, 5)) }
        var found = Set<String>()
        var start = 0
        var weight = 0
        for end in words.indices {
            weight += words[end].1
            while weight - words[start].1 >= 30 {
                weight -= words[start].1
                start += 1
            }
            if weight >= 30 {
                found.insert(words[start...end].map(\.0).joined(separator: " "))
            }
        }
        return found
    }

    // MARK: The sweep

    /// The passages of one mail by one rule of the sweep.
    private struct SweptRow: Codable {
        var rule: String
        var id: String
        var picked: [Picked]
    }

    /// A rule for other projects' passages that the sweep tries.
    private struct Variant {
        var name: String
        var rule: ExplainService.OtherProjectsRule
        /// Whether their passages take the places of the project's weakest, as in round 2,
        /// rather than come after its six, as the app has them.
        var replacing = false
    }

    /// The rules of round 2, which searched other projects when fewer than a number of the
    /// project's own passages matched a term, and the ranking of all projects, with other
    /// projects' passages in place of the project's weakest or after its 6, and one, two or
    /// three terms a passage must match for Needs a Project. The app's rule is the last but
    /// one.
    private static let variants: [Variant] = [
        Variant(name: "own term matches 1", rule: .init(inProject: .ownTermMatches(1), needsProjectTerms: 1), replacing: true),
        Variant(name: "own term matches 2", rule: .init(inProject: .ownTermMatches(2), needsProjectTerms: 1), replacing: true),
        Variant(name: "own term matches 3", rule: .init(inProject: .ownTermMatches(3), needsProjectTerms: 1), replacing: true),
        Variant(name: "own term matches 7", rule: .init(inProject: .ownTermMatches(7), needsProjectTerms: 1), replacing: true),
        Variant(name: "ranked above, in place of the weakest", rule: .init(needsProjectTerms: 1), replacing: true),
        Variant(name: "ranked above, after the own 6", rule: .init(needsProjectTerms: 1)),
        Variant(name: "ranked above, in place of the weakest, Needs a Project 2 terms", rule: .init(needsProjectTerms: 2), replacing: true),
        Variant(name: "ranked above, after the own 6, Needs a Project 2 terms", rule: .init(needsProjectTerms: 2)),
        Variant(name: "ranked above, in place of the weakest, Needs a Project 3 terms", rule: .init(needsProjectTerms: 3), replacing: true),
        Variant(name: "ranked above, after the own 6, Needs a Project 3 terms", rule: .init(needsProjectTerms: 3)),
        Variant(name: "ranked above, after the own 6, Needs a Project 3 terms, no name or date in any search", rule: .init(needsProjectTerms: 3, namesSearchTheProject: false)),
    ]

    // MARK: The report

    private static let subsets = ["plain", "zh-en", "en-zh", "synonym", "other-project", "needs-project", "negative"]

    private static func report(_ rows: [Row], sweeps: [String: [String: [Picked]]], leaks: [Leak], files: Int, chunks: Int, indexTime: Duration, measuredTerms: Bool) -> String {
        func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        func subset(_ name: String) -> [Row] { rows.filter { $0.kinds.contains(name) } }
        var text = "# Retrieval with search terms\n\n\(rows.count) labeled mails, \(files) files in \(chunks) chunks, indexed in \(seconds(indexTime)). Recall at 6 is the share of a mail's relevant files among the passages a prompt holds before its budget: at most 6 of the email's project, and for an email in a project at most \(ExplainService.otherProjectChunks) of other projects after them, or at most 6 of other projects for an email in Needs a Project. Hit at 6 says that one of them is there.\n\n"
        text += "Before is the selection of 0.6.0, without terms and with every passage of a file. After has the terms and at most \(ExplainService.perFileChunks) passages of a file before the passages of other files. The two columns between take one of the changes alone.\n\n"
        text += "| Subset | Mails | Recall before | Recall, cap alone | Recall, terms alone | Recall after | Hit before | Hit after | First relevant rank after, median | Other projects' passages a mail |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for name in subsets + ["zh-en or en-zh"] {
            let chosen = name == "zh-en or en-zh" ? rows.filter { !Set($0.kinds).isDisjoint(with: ["zh-en", "en-zh"]) } : subset(name)
            guard !chosen.isEmpty else { continue }
            let ranks = chosen.compactMap { $0.firstRank($0.after) }.sorted()
            text += "| \(name) | \(chosen.count) | \(percent(mean(chosen.map { $0.recall($0.before) }))) | \(percent(mean(chosen.map { $0.recall($0.beforeCapped) }))) | \(percent(mean(chosen.map { $0.recall($0.afterUncapped) }))) | \(percent(mean(chosen.map { $0.recall($0.after) }))) | \(percent(mean(chosen.map { $0.hit($0.before) ? 1 : 0 }))) | \(percent(mean(chosen.map { $0.hit($0.after) ? 1 : 0 }))) | \(ranks.isEmpty ? "-" : String(ranks[ranks.count / 2])) | \(String(format: "%.2f", mean(chosen.map { Double($0.after.filter { $0.project != nil }.count) }))) |\n"
        }
        let lost = subset("plain").filter { row in
            let before = Set(row.before.map(\.path)).intersection(row.relevant)
            return !before.isSubset(of: Set(row.after.map(\.path)))
        }
        let negatives = subset("negative")
        let negativesWithOthers = negatives.filter { $0.after.contains { $0.project != nil } }
        let valid = rows.filter(\.termsValid)
        let times = rows.map(\.termsSeconds).filter { $0 > 0 }.sorted()
        let searches = rows.flatMap(\.searchSeconds).sorted()
        func quantile(_ values: [Double], _ fraction: Double) -> Double {
            values.isEmpty ? 0 : values[min(values.count - 1, max(0, Int((Double(values.count) * fraction).rounded(.up)) - 1))]
        }
        var causes: [String: Int] = [:]
        for row in rows {
            if let cause = row.termsFallback { causes[cause, default: 0] += 1 }
        }
        var reasons: [String: Int] = [:]
        for row in rows {
            reasons[row.otherProjectsAfter, default: 0] += 1
        }
        text += "\nMails of the set that lost a relevant file they had before: \(lost.count)" + (lost.isEmpty ? "" : ", " + lost.map(\.id).joined(separator: ", ")) + ".\n"
        text += "Negatives that get a passage of another project: \(negativesWithOthers.count) of \(negatives.count)" + (negativesWithOthers.isEmpty ? "" : ", " + negativesWithOthers.map(\.id).joined(separator: ", ")) + ".\n"
        text += "Terms: valid for \(valid.count) of \(rows.count) mails (\(percent(Double(valid.count) / Double(max(rows.count, 1))))), \(String(format: "%.1f", mean(valid.map { Double($0.terms) }))) a mail, fallbacks \(causes.isEmpty ? "none" : causes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")).\n"
        if measuredTerms {
            text += "Terms job: median \(String(format: "%.2f", quantile(times, 0.5))) s, p90 \(String(format: "%.2f", quantile(times, 0.9))) s, at most \(String(format: "%.2f", times.last ?? 0)) s, \(times.filter { $0 > SearchTerms.timeLimit / .seconds(1) }.count) over the time limit.\n"
        }
        text += "Search: p90 \(String(format: "%.3f", quantile(searches, 0.9))) s over \(searches.count) searches.\n"
        text += "Other projects after: " + reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ".\n"

        // The bar of E 9.6 that this run measures.
        let plain = subset("plain")
        let crossing = rows.filter { !Set($0.kinds).isDisjoint(with: ["zh-en", "en-zh"]) }
        let synonym = subset("synonym")
        func recall(_ rows: [Row], _ after: Bool) -> Double { mean(rows.map { after ? $0.recall($0.after) : $0.recall($0.before) }) }
        func hit(_ rows: [Row]) -> Double { mean(rows.map { $0.hit($0.after) ? 1 : 0 }) }
        let checks: [(String, Bool)] = [
            ("the set's mails: recall at least before minus 1 point (\(percent(recall(plain, false))) to \(percent(recall(plain, true))))", recall(plain, true) >= recall(plain, false) - 0.01),
            ("the set's mails: at most 2 lost a relevant file (\(lost.count))", lost.count <= 2),
            ("zh-en and en-zh: recall 60% or more and 30 points above before (\(percent(recall(crossing, false))) to \(percent(recall(crossing, true))))", recall(crossing, true) >= 0.6 && recall(crossing, true) - recall(crossing, false) >= 0.3),
            ("synonym: recall 60% or more and 20 points above before (\(percent(recall(synonym, false))) to \(percent(recall(synonym, true))))", recall(synonym, true) >= 0.6 && recall(synonym, true) - recall(synonym, false) >= 0.2),
            ("other-project: hit 60% or more (\(percent(hit(subset("other-project")))))", hit(subset("other-project")) >= 0.6),
            ("needs-project: hit 60% or more (\(percent(hit(subset("needs-project")))))", hit(subset("needs-project")) >= 0.6),
            ("negative: at most 3 get another project's passage (\(negativesWithOthers.count))", negativesWithOthers.count <= 3),
            ("terms valid for 95% or more (\(percent(Double(valid.count) / Double(max(rows.count, 1)))))", Double(valid.count) >= 0.95 * Double(rows.count)),
        ] + (measuredTerms ? [
            ("terms job: no time limit reached, median 2.0 s or less, p90 3.5 s or less", times.allSatisfy { $0 <= SearchTerms.timeLimit / .seconds(1) } && quantile(times, 0.5) <= 2.0 && quantile(times, 0.9) <= 3.5),
        ] : [])
        text += "\n## The bar\n\n" + checks.map { "- \($0.1 ? "passed" : "FAILED"): \($0.0)" }.joined(separator: "\n") + "\n"

        if !sweeps.isEmpty {
            text += "\n## Sweep\n\nEach rule for other projects' passages, with the terms of this run. Negatives count those in a project and those without one. A rule after the own 6 lets the prompt hold up to 8 passages.\n\n| Rule | Recall, set | Set mails that lost a file | Recall, zh-en and en-zh | Recall, synonym | Hit, other-project | Hit, needs-project | Negatives with another project's passage | Bars met of 7 |\n|---|---|---|---|---|---|---|---|---|\n"
            for variant in variants {
                guard let picked = sweeps[variant.name] else { continue }
                func swept(_ rows: [Row]) -> [Row] {
                    rows.map { row in
                        var row = row
                        row.after = picked[row.id] ?? row.after
                        return row
                    }
                }
                let sweptPlain = swept(plain)
                let sweptLost = sweptPlain.filter { row in
                    !Set(row.before.map(\.path)).intersection(row.relevant).isSubset(of: Set(row.after.map(\.path)))
                }.count
                let sweptNegatives = swept(negatives).filter { $0.after.contains { $0.project != nil } }
                let inProject = sweptNegatives.filter { $0.project != "none" }.count
                let bars = [
                    recall(sweptPlain, true) >= recall(plain, false) - 0.01,
                    sweptLost <= 2,
                    recall(swept(crossing), true) >= 0.6 && recall(swept(crossing), true) - recall(crossing, false) >= 0.3,
                    recall(swept(synonym), true) >= 0.6 && recall(swept(synonym), true) - recall(synonym, false) >= 0.2,
                    hit(swept(subset("other-project"))) >= 0.6,
                    hit(swept(subset("needs-project"))) >= 0.6,
                    sweptNegatives.count <= 3,
                ].filter { $0 }.count
                text += "| \(variant.name) | \(percent(recall(sweptPlain, true))) | \(sweptLost) | \(percent(recall(swept(crossing), true))) | \(percent(recall(swept(synonym), true))) | \(percent(hit(swept(subset("other-project"))))) | \(percent(hit(swept(subset("needs-project"))))) | \(sweptNegatives.count) (\(inProject) + \(sweptNegatives.count - inProject)) | \(bars) |\n"
            }
        }
        if !leaks.isEmpty {
            let apart = leaks.filter(\.draftApart)
            let found = apart.filter { !$0.found.isEmpty }
            text += "\n## Leak check\n\n\(apart.count) explanations as the app makes them, \(apart.filter { $0.draft != nil }.count) checked drafts with other projects' passages in their explanation's prompt, \(found.count) with another project's value, code, address, name or run: " + (found.isEmpty ? "none" : found.map { "\($0.id) \($0.language)" }.joined(separator: ", ")) + ".\n"
            let together = leaks.filter { !$0.draftApart }
            let foundTogether = together.filter { !$0.found.isEmpty }
            text += "With one request, as before: \(together.filter { $0.draft != nil }.count) checked drafts with other projects' passages in their prompt, \(foundTogether.count) with another project's value, code, address, name or run: " + (foundTogether.isEmpty ? "none" : foundTogether.map { "\($0.id) \($0.language)" }.joined(separator: ", ")) + ".\n"
            text += "\n| Explanations | With the draft apart, median | p90 | Requests | With one request, median | p90 | Requests |\n|---|---|---|---|---|---|---|\n"
            for (name, chosen) in [("all \(apart.count)", { (_: Leak) in true }), ("with other projects' passages", { (leak: Leak) in leak.otherPassages > 0 })] as [(String, (Leak) -> Bool)] {
                let two = apart.filter(chosen)
                let one = together.filter { leak in chosen(leak) && apart.contains { $0.id == leak.id && $0.language == leak.language && chosen($0) } }
                func times(_ leaks: [Leak]) -> [Double] { leaks.map(\.seconds).sorted() }
                text += "| \(name == "with other projects' passages" ? "\(two.count) \(name)" : name) | \(String(format: "%.1f s", quantile(times(two), 0.5))) | \(String(format: "%.1f s", quantile(times(two), 0.9))) | \(two.map(\.requests).reduce(0, +)) | \(String(format: "%.1f s", quantile(times(one), 0.5))) | \(String(format: "%.1f s", quantile(times(one), 0.9))) | \(one.map(\.requests).reduce(0, +)) |\n"
            }
        }
        return text
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", duration / .seconds(1))
    }
}

/// The synthetic set and its owner, from the environment, so neither is in the repository.
nonisolated enum RetrievalSet {
    /// The set's folder in TEST_RUNNER_ORRA_PROJECTS_RETRIEVAL, when it holds the supplement's
    /// labels.
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORRA_PROJECTS_RETRIEVAL"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("retrieval/labels.jsonl").path) ? url : nil
    }

    static let ownAddresses: [String] = (ProcessInfo.processInfo.environment["ORRA_PROJECTS_OWN_ADDRESSES"] ?? "")
        .split(separator: ",")
        .compactMap { ProjectsAddress.normalized(String($0)) }

    static let ownName = ProcessInfo.processInfo.environment["ORRA_PROJECTS_OWN_NAME"] ?? ""
}
