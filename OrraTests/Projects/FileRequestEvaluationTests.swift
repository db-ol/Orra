import Foundation
import Testing
@testable import Orra

/// Measures which files the mails of the synthetic Projects set ask for, see FileRequests,
/// and which files Projects offers for them, see RequestedFiles, over the set, its retrieval
/// supplement, the request mails beside it and the attack items. Only when asked for, never
/// in CI, and in a Release build, since it times the search:
///
///     TEST_RUNNER_ORRA_FILE_REQUESTS=~/projects/orra-project/bench/projects-testset \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES=<work address>,<home address> \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_NAME=<name> \
///     TEST_RUNNER_ORRA_FILE_REQUESTS_OUT=<folder> \
///     xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/FileRequestEvaluationTests
///
/// The set's folder holds the request mails in retrieval/requests/: mail.jsonl, folders/
/// <project>/ with the files they ask for that the set lacks, and labels.jsonl, one line a
/// mail of the set, the supplement, the requests or the attack items that asks for a file,
/// with the kinds of document it asks for, the files that answer it as paths in the set's
/// folder, and whether its sender is spoofed. Every other mail asks for nothing.
/// docs/release-gate.md describes them. FolderIndex indexes each project with its folder of
/// the set, of the supplement and of the requests.
///
/// For each mail the user received it builds the email and the people the user knows as
/// RetrievalEvaluationTests does, its thread from the set's thread ids and Message-ID links,
/// or for an attack item from its earlier messages, and its project from the labels. It
/// finds the warnings and whether a reply is due as `ExplainService.prepare` does, the facts
/// of the reply as `finish` does, where the files are looked for as the email view does, by
/// the warnings about the email itself, see ProjectsReplyFiles.scopeWarnings(_:listed:) and
/// scope(warnings:emailProject:), and the files of each request with RequestedFiles. It
/// needs no model and no Mail, and sends no Apple Event. It writes file-requests.jsonl, one
/// row a mail, and file-requests.md with the tables, the bar, the files offered to the
/// attack items and the files of other projects offered, and prints counts only.
///
/// TEST_RUNNER_ORRA_FILE_REQUESTS_MODE is both, as the app searches and the default, names
/// or text, which fuse the name lists or the text list alone, or terms, which adds the
/// search terms of retrieval-terms.jsonl in TEST_RUNNER_ORRA_FILE_REQUESTS_TERMS, an output
/// folder of RetrievalEvaluationTests, to the text search of each kind. Mails without saved
/// terms search without.
///
/// The set and the results stay outside the repository.
@Suite(.serialized, .enabled(if: FileRequestSet.folder != nil && !RetrievalSet.ownAddresses.isEmpty))
@MainActor
struct FileRequestEvaluationTests {
    private nonisolated static let today = ISO8601DateFormatter().date(from: "2026-10-18T20:00:00+08:00")!
    private nonisolated static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    @Test func measureTheRequests() async throws {
        let root = try #require(FileRequestSet.folder)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: ((environment["ORRA_FILE_REQUESTS_OUT"] ?? NSTemporaryDirectory()) as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mode = try #require(Mode(rawValue: environment["ORRA_FILE_REQUESTS_MODE"] ?? "both"), "the mode is names, text, both or terms")
        let supplement = root.appendingPathComponent("retrieval", isDirectory: true)
        let requestsFolder = supplement.appendingPathComponent("requests", isDirectory: true)
        let ownAddresses = Set(RetrievalSet.ownAddresses)

        // Every mail, with where it comes from.
        let decoder = JSONDecoder()
        var mails: [Mail] = []
        for (source, file) in [
            (Source.set, root.appendingPathComponent("mail.jsonl")),
            (.supplement, supplement.appendingPathComponent("mail.jsonl")),
            (.requests, requestsFolder.appendingPathComponent("mail.jsonl")),
        ] {
            for line in try Self.lines(file) {
                let row = try decoder.decode(SetRow.self, from: line)
                mails.append(Mail(id: row.id, source: source, language: row.language ?? "", project: row.message.labels?.project, thread: row.thread, message: row.message))
            }
        }
        let messages = mails.map(\.message)
        for line in try Self.lines(root.appendingPathComponent("adversarial.jsonl")) {
            let item = try decoder.decode(AttackItem.self, from: line)
            guard let last = item.messages.last else { continue }
            mails.append(Mail(
                id: item.id, source: .attacks, language: last.language ?? "", project: item.expected?.project ?? item.context_project,
                thread: nil, message: last.message, earlier: item.messages.dropLast().map(\.message), attack: item.attack ?? []))
        }
        var labels: [String: Label] = [:]
        for line in try Self.lines(requestsFolder.appendingPathComponent("labels.jsonl")) {
            let label = try decoder.decode(Label.self, from: line)
            try #require(mails.contains { $0.id == label.id }, "no mail \(label.id)")
            labels[label.id] = label
        }
        try #require(!labels.isEmpty)

        // The projects, with the set's ids.
        let setProjects = try decoder.decode([SetProject].self, from: Data(contentsOf: root.appendingPathComponent("projects/projects.json")))
        let ids = Dictionary(uniqueKeysWithValues: setProjects.enumerated().map { index, project in
            (project.slug, UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!)
        })
        let slugs = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
        let projects = setProjects.map { project in
            ExplainService.Project(id: ids[project.slug]!, name: project.name, description: project.description, people: project.people.map(GateAttackSet.person), domains: project.domains)
        }

        // The index, with each project's folders of the set, the supplement and the requests.
        // It holds the set's text, so it goes whichever way the run ends.
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FileRequestEvaluationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try await ProjectsDatabase.open(in: ProjectsStorage(root: storageRoot))
        let index = FolderIndex(database: database, isDictating: { false }, watch: { _, _, _ in {} })
        let indexStarted = ContinuousClock.now
        var projectFiles: [String: URL] = [:]
        for project in setProjects {
            let folders = [
                root.appendingPathComponent(project.folder, isDirectory: true),
                supplement.appendingPathComponent("folders/\(project.slug)", isDirectory: true),
                requestsFolder.appendingPathComponent("folders/\(project.slug)", isDirectory: true),
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
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
        let files = try await database.run("SELECT count(*) FROM index_files").first?.first?.integer ?? 0
        let names = FileNameSearch(database: database)
        let chunks = ChunkSearch(database: database)
        let realRoot = root.resolvingSymlinksInPath().path + "/"
        func relative(_ url: URL) -> String {
            let path = url.path
            return path.hasPrefix(realRoot) ? String(path.dropFirst(realRoot.count)) : path
        }

        // The terms of RetrievalEvaluationTests, for the terms mode.
        var savedTerms: [String: [String]] = [:]
        if mode == .terms {
            let path = try #require(environment["ORRA_FILE_REQUESTS_TERMS"], "the terms mode reads TEST_RUNNER_ORRA_FILE_REQUESTS_TERMS")
            var file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if file.pathExtension != "jsonl" {
                file = file.appendingPathComponent("retrieval-terms.jsonl")
            }
            for line in try Self.lines(file) {
                let run = try decoder.decode(TermsRun.self, from: line)
                if let terms = run.terms, !terms.isEmpty {
                    savedTerms[run.id] = terms
                }
            }
        }

        var rows: [Row] = []
        for mail in mails {
            let message = mail.message
            let sender = GateAttackSet.person(message.from)
            guard !(ProjectsAddress.normalized(sender.address).map(ownAddresses.contains) ?? false) else { continue }
            let project = mail.project.flatMap { ids[$0] }
            let visible = GateAttackSet.visible(message)
            let email = ExplainService.Email(
                messageID: GateAttackSet.bare(message.message_id), date: GateAttackSet.date(message.date), sender: sender,
                to: message.to.map(GateAttackSet.person), cc: (message.cc ?? []).map(GateAttackSet.person), subject: message.subject,
                attachments: await Self.attachments(of: message, files: projectFiles),
                text: QuotedHistory(splitting: visible.text, subject: message.subject).ownText, visibleText: visible.text,
                hiddenText: visible.hidden, project: project)
            let known = Self.known(before: email, messages: messages + mail.earlier, projects: projects, ownAddresses: ownAddresses)
            let thread = mail.source == .attacks
                ? mail.earlier.map(GateAttackSet.promptMail)
                : Self.thread(of: mail, in: mails).map(GateAttackSet.promptMail)

            // The warnings, the reply and its facts, as an explanation finds them in code.
            var gathered = ExplainService.Gathered(email: email, known: known, project: projects.first { $0.id == project }, thread: thread, today: Self.today)
            gathered.ruleWarnings = await ExplainService.ruleWarnings(email, known: known)
            let prepared = await ExplainService.prepare(gathered, language: .en, timeZone: Self.timeZone, countTokens: { $0.count })
            let facts = ExplainService.replyFacts(prepared)
            let warnings = Set(prepared.prompt.checks.map(\.warning))
            // Where the view looks: by the warnings about the email itself, not those of the
            // thread's messages.
            let emailWarnings = ProjectsReplyFiles.scopeWarnings(prepared.prompt.checks, listed: [])
            let replyIsDue = if case .reply = prepared.reply { true } else { false }
            let scope = ProjectsReplyFiles.scope(warnings: emailWarnings, emailProject: project)
            let requests = replyIsDue ? facts?.requests ?? [] : []
            let terms = savedTerms[mail.id] ?? []

            // The files of each request as the email view shows them: in its scope, and a file
            // found for an earlier request there only.
            let (searchesFiles, searched): (Bool, [UUID]?) = switch scope {
            case .everyProject: (true, nil)
            case .ownProject(let own): (true, [own])
            case .nowhere, .spoofed: (false, nil)
            }
            func search(_ request: FileRequest) async throws -> [RequestedFile] {
                guard searchesFiles else { return [] }
                return try await RequestedFiles.find(
                    request, emailProject: project, scope: searched, names: names, chunks: chunks,
                    lists: mode.lists, searchTerms: mode == .terms ? terms : [])
            }
            func offered(_ files: [RequestedFile]) -> [Offered] {
                files.enumerated().map { Offered(path: relative($0.element.url), project: slugs[$0.element.project] ?? "?", rank: $0.offset + 1, older: $0.element.isOlderVersion) }
            }
            var searches: [Double] = []
            var shown: Set<String> = []
            var found: [Found] = []
            for request in requests {
                let started = ContinuousClock.now
                var files = try await search(request)
                if searchesFiles {
                    searches.append(started.duration(to: .now) / .milliseconds(1))
                }
                files.removeAll { shown.contains($0.id) }
                shown.formUnion(files.map(\.id))
                found.append(Found(kinds: Self.kinds(of: request), object: request.object, fileNames: request.fileNames, files: offered(files)))
            }

            // Each kind the labels give, with the files of the request found for it, searched
            // for that kind alone, as its group of the view lists them.
            let label = labels[mail.id]
            var asked: [Asked] = []
            for kind in label?.asks ?? [] {
                guard let request = requests.first(where: { Self.kinds(of: $0).contains(kind) }) else {
                    asked.append(Asked(kind: kind, found: false, files: [], rank: nil))
                    continue
                }
                let alone = kind == DocumentKind.document.rawValue
                    ? request
                    : FileRequest(sentence: request.sentence, object: request.object, kinds: [kind], fileNames: request.fileNames)
                let files = offered(try await search(alone))
                let rank = files.first { label?.expect.contains($0.path) ?? false }?.rank
                asked.append(Asked(kind: kind, found: true, files: files, rank: rank))
            }
            // The requests in the sender's words before the reply rule, for the rows of mails
            // that get no reply.
            let inWords = FileRequests.find(in: ExplainService.sendersOwnWords(email), subject: email.subject)
            rows.append(Row(
                id: mail.id, source: mail.source.rawValue, language: mail.language, project: mail.project ?? "none",
                replyIsDue: replyIsDue, senderIsKnown: facts?.senderIsKnown,
                warnings: ProjectsWarning.allCases.filter(warnings.contains).map(\.rawValue),
                emailWarnings: ProjectsWarning.allCases.filter(emailWarnings.contains).map(\.rawValue), scope: Self.name(scope),
                requests: found, kindsInWords: Array(Set(inWords.flatMap(Self.kinds(of:)))).sorted(),
                asks: label?.asks ?? [], expect: label?.expect ?? [],
                spoofed: (label?.spoofed ?? false) || !Set(mail.attack).isDisjoint(with: ["lookalike_domain", "sender_name_mismatch"]),
                subsets: label?.subsets ?? [], asked: asked, milliseconds: searches.isEmpty ? nil : searches.reduce(0, +)))
        }
        await database.close()

        // The rows and the report, outside the repository.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n").appending("\n")
            .write(to: out.appendingPathComponent("file-requests.jsonl"), atomically: true, encoding: .utf8)
        let report = Self.report(rows, mode: mode, termsMails: rows.filter { savedTerms[$0.id] != nil }.count, files: Int(files), indexTime: indexTime)
        try report.write(to: out.appendingPathComponent("file-requests.md"), atomically: true, encoding: .utf8)
        // Counts only.
        print("File requests (\(mode.rawValue)): \(rows.count) mails, \(rows.filter { !$0.requests.isEmpty }.count) with requests, \(rows.map { $0.requests.map(\.files.count).reduce(0, +) }.reduce(0, +)) files offered, \(files) files indexed in \(String(format: "%.1f s", indexTime / .seconds(1))). Rows in file-requests.jsonl, tables in file-requests.md.")
        #expect(rows.count == mails.filter { mail in !(ProjectsAddress.normalized(GateAttackSet.person(mail.message.from).address).map(ownAddresses.contains) ?? false) }.count)
    }

    // MARK: The set

    private enum Source: String {
        case set, supplement, requests, attacks
    }

    /// Which lists the search fuses, see RequestedFiles.Lists.
    private enum Mode: String {
        case names, text, both, terms

        var lists: RequestedFiles.Lists {
            switch self {
            case .names: .names
            case .text: .text
            case .both, .terms: .both
            }
        }
    }

    /// A line of mail.jsonl: the message, with its id, language and thread.
    private struct SetRow: Decodable {
        let id: String
        let language: String?
        let thread: String?
        let message: GateAttackSet.Message

        enum CodingKeys: String, CodingKey {
            case id, language, thread
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            thread = try container.decodeIfPresent(String.self, forKey: .thread)
            message = try GateAttackSet.Message(from: decoder)
        }
    }

    /// An attack item: its messages, the last of which is the email, its project and the
    /// kinds of attack it holds.
    private struct AttackItem: Decodable {
        struct Expected: Decodable {
            let project: String?
        }

        struct Message: Decodable {
            let language: String?
            let message: GateAttackSet.Message

            enum CodingKeys: String, CodingKey {
                case language
            }

            init(from decoder: any Decoder) throws {
                language = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .language)
                message = try GateAttackSet.Message(from: decoder)
            }
        }

        let id: String
        let context_project: String
        let attack: [String]?
        let expected: Expected?
        let messages: [Message]
    }

    private struct SetProject: Decodable {
        let slug: String
        let name: String
        let description: String
        let folder: String
        let people: [String]
        let domains: [String]
    }

    /// A mail that asks for files: the kinds of document it asks for, as raw values of
    /// DocumentKind, document for a file it names by no kind, the files that answer it as
    /// paths in the set's folder, none for a file no folder holds, whether its sender is
    /// spoofed, and the subsets it belongs to.
    private struct Label: Decodable {
        let id: String
        let asks: [String]
        let expect: [String]
        let spoofed: Bool
        let subsets: [String]?
    }

    /// The terms of a mail in retrieval-terms.jsonl.
    private struct TermsRun: Decodable {
        let id: String
        let terms: [String]?
    }

    private struct Mail {
        var id: String
        var source: Source
        var language: String
        /// The labeled project's slug, nil for a mail in no project.
        var project: String?
        var thread: String?
        var message: GateAttackSet.Message
        /// An attack item's earlier messages.
        var earlier: [GateAttackSet.Message] = []
        var attack: [String] = []
    }

    // MARK: The rows

    /// A file offered: its path in the set's folder, its project, its place from 1, and
    /// whether a newer file of the list replaced it.
    private struct Offered: Codable {
        var path: String
        var project: String
        var rank: Int
        var older: Bool
    }

    /// A request of the facts, with the files the view offers for it.
    private struct Found: Codable {
        var kinds: [String]
        var object: String
        var fileNames: [String]
        var files: [Offered]
    }

    /// A kind the labels give, whether a request of the facts names it, the files searched
    /// for it alone, and the place of the first file that answers it.
    private struct Asked: Codable {
        var kind: String
        var found: Bool
        var files: [Offered]
        var rank: Int?
    }

    private struct Row: Codable {
        var id: String
        var source: String
        var language: String
        var project: String
        var replyIsDue: Bool
        var senderIsKnown: Bool?
        /// Every warning the checks found, the thread's messages too.
        var warnings: [String]
        /// The warnings about the email itself, which decide the scope, see
        /// ProjectsReplyFiles.scopeWarnings(_:listed:).
        var emailWarnings: [String]
        var scope: String
        var requests: [Found]
        /// The kinds FileRequests finds in the sender's words, a reply due or not.
        var kindsInWords: [String]
        var asks: [String]
        var expect: [String]
        /// Whether the sender is spoofed, by the labels or the attack item's kinds.
        var spoofed: Bool
        var subsets: [String]
        var asked: [Asked]
        /// The time of the searches of the view, nil without any.
        var milliseconds: Double?

        /// The kinds the facts name, each once.
        var kinds: Set<String> {
            Set(requests.flatMap(\.kinds))
        }

        var offersFiles: Bool {
            requests.contains { !$0.files.isEmpty }
        }
    }

    // MARK: Helpers

    private nonisolated static func lines(_ url: URL) throws -> [Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { Data($0.utf8) }
    }

    /// The kinds a request names, document for one that names only a file or no kind.
    private nonisolated static func kinds(of request: FileRequest) -> [String] {
        let kinds = request.documentKinds.filter { !$0.isGeneric }.map(\.rawValue)
        return kinds.isEmpty ? [DocumentKind.document.rawValue] : kinds
    }

    private nonisolated static func name(_ scope: ProjectsReplyFiles.Scope) -> String {
        switch scope {
        case .everyProject: "every project"
        case .ownProject: "own project"
        case .nowhere: "nowhere"
        case .spoofed: "spoofed"
        }
    }

    /// The other mails of the thread: those with its thread id, and those its In-Reply-To
    /// and References name, in date order.
    private nonisolated static func thread(of mail: Mail, in mails: [Mail]) -> [GateAttackSet.Message] {
        var found: [String: GateAttackSet.Message] = [:]
        let ids = Set(([mail.message.in_reply_to].compactMap { $0 } + (mail.message.references ?? [])).map(GateAttackSet.bare))
        for other in mails where other.source != .attacks && other.id != mail.id {
            if let thread = mail.thread, other.thread == thread {
                found[other.id] = other.message
            } else if ids.contains(GateAttackSet.bare(other.message.message_id)) {
                found[other.id] = other.message
            }
        }
        return found.values.sorted { GateAttackSet.date($0.date) < GateAttackSet.date($1.date) }
    }

    /// The user and the people on mail dated before the email, so a stranger's first email
    /// never makes its sender known.
    private nonisolated static func known(before email: ExplainService.Email, messages: [GateAttackSet.Message], projects: [ExplainService.Project], ownAddresses: Set<String>) -> ExplainService.Known {
        let earlier = messages.filter { GateAttackSet.date($0.date) < email.date }
        var correspondents: [SenderChecks.Person] = []
        var seen: Set<String> = []
        for message in earlier {
            for value in [message.from] + message.to + (message.cc ?? []) {
                let person = GateAttackSet.person(value)
                guard let address = ProjectsAddress.normalized(person.address), !ownAddresses.contains(address), seen.insert(address).inserted else { continue }
                correspondents.append(SenderChecks.Person(name: person.name, address: address))
            }
        }
        let sent = earlier.filter { ProjectsAddress.normalized(GateAttackSet.person($0.from).address).map(ownAddresses.contains) ?? false }.map(\.body)
        return ExplainService.Known(ownName: RetrievalSet.ownName, ownAddresses: RetrievalSet.ownAddresses, projects: projects, correspondents: correspondents, sentTexts: sent)
    }

    /// The attachments as the scan reads them: with the file of the project folders that has
    /// the attachment's name, or a file of its type made from an attack item's text, else as
    /// a name and a type.
    private nonisolated static func attachments(of message: GateAttackSet.Message, files: [String: URL]) async -> [MailAttachment] {
        let attached = (message.attachments ?? []).map { attachment in
            let data = files[attachment.name].flatMap { try? Data(contentsOf: $0) }
                ?? attachment.text.flatMap { GateAttackSet.file($0, name: attachment.name, type: attachment.type) }
            return AttachedFiles.File(name: attachment.name, type: attachment.type, data: data ?? Data())
        }
        return await MailAttachment.read(AttachedFiles.parts(attached), modified: GateAttackSet.date(message.date))
    }

    // MARK: The report

    private static let languages = ["en", "zh", "ja", "es"]

    private static func report(_ rows: [Row], mode: Mode, termsMails: Int, files: Int, indexTime: Duration) -> String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "-" }
        func ratio(_ part: Int, _ whole: Int) -> Double? { whole == 0 ? nil : Double(part) / Double(whole) }
        func quantile(_ values: [Double], _ fraction: Double) -> Double {
            values.isEmpty ? 0 : values[min(values.count - 1, max(0, Int((Double(values.count) * fraction).rounded(.up)) - 1))]
        }
        let modeLine = switch mode {
        case .names: "the name lists alone"
        case .text: "the text list alone"
        case .both: "the name lists and the text list, as the app searches"
        case .terms: "the name lists and the text list, with the saved search terms of \(termsMails) mails in the text search"
        }
        var text = "# Files an email asks for\n\n\(rows.count) mails the user received: \(rows.filter { $0.source == "set" }.count) of the set, \(rows.filter { $0.source == "supplement" }.count) of the supplement, \(rows.filter { $0.source == "requests" }.count) request mails and \(rows.filter { $0.source == "attacks" }.count) attack items. \(files) files indexed in \(String(format: "%.1f s", indexTime / .seconds(1))). The search fuses \(modeLine).\n\n"

        // Detection, by mail and kind.
        struct Counts {
            var truePositives = 0, falsePositives = 0, falseNegatives = 0, beforeRule = 0
        }
        func counts(_ rows: [Row]) -> Counts {
            var counts = Counts()
            for row in rows {
                let asked = Set(row.asks)
                counts.truePositives += row.kinds.intersection(asked).count
                counts.falsePositives += row.kinds.subtracting(asked).count
                counts.falseNegatives += asked.subtracting(row.kinds).count
                counts.beforeRule += Set(row.kindsInWords).intersection(asked).count
            }
            return counts
        }
        func precision(_ counts: Counts) -> Double? { ratio(counts.truePositives, counts.truePositives + counts.falsePositives) }
        func recall(_ counts: Counts) -> Double? { ratio(counts.truePositives, counts.truePositives + counts.falseNegatives) }
        text += "## Detection\n\nA request counts by mail and kind, document for a request that names only a file. Found is what the facts of a reply hold, so a mail that gets no reply finds nothing. Recall in the words is that of the requests in the sender's words before the reply rule.\n\n"
        text += "| Language | Mails | Asking | Kinds asked | Kinds found | Right | Precision | Recall | Recall in the words |\n|---|---|---|---|---|---|---|---|---|\n"
        let groups = languages.map { language in (language, rows.filter { $0.language == language }) } + [("other", rows.filter { !languages.contains($0.language) }), ("all", rows)]
        for (name, chosen) in groups where !chosen.isEmpty {
            let found = counts(chosen)
            text += "| \(name) | \(chosen.count) | \(chosen.filter { !$0.asks.isEmpty }.count) | \(found.truePositives + found.falseNegatives) | \(found.truePositives + found.falsePositives) | \(found.truePositives) | \(percent(precision(found))) | \(percent(recall(found))) | \(percent(ratio(found.beforeRule, found.truePositives + found.falseNegatives))) |\n"
        }
        let missed = rows.filter { !Set($0.asks).subtracting($0.kinds).isEmpty }.map { row in "\(row.id) (\(Set(row.asks).subtracting(row.kinds).sorted().joined(separator: ", "))\(row.replyIsDue ? "" : ", no reply due"))" }
        let extra = rows.filter { !$0.kinds.subtracting($0.asks).isEmpty }.map { row in "\(row.id) (\(row.kinds.subtracting(row.asks).sorted().joined(separator: ", ")))" }
        text += "\nMissed: " + (missed.isEmpty ? "none" : missed.joined(separator: ", ")) + ".\nFound without a label: " + (extra.isEmpty ? "none" : extra.joined(separator: ", ")) + ".\n"

        // Offers, for the kinds whose file exists.
        let answerable = rows.flatMap { row in row.asked.filter { _ in !row.expect.isEmpty && !row.spoofed }.map { (row: row, asked: $0) } }
        text += "\n## Offers\n\nHit at 1 and at 3: a file that answers the request among the first one or three files of its kind. A kind the facts miss counts as missed. Among found counts only the kinds the facts name.\n\n"
        text += "| Subset | Kinds | Hit at 1 | Hit at 3 | Hit at 3 among found | Missed files |\n|---|---|---|---|---|---|\n"
        let subsets = ["other-language", "no-text", "other-project", "file-name"]
        for name in ["all"] + subsets {
            let chosen = name == "all" ? answerable : answerable.filter { $0.row.subsets.contains(name) }
            guard !chosen.isEmpty else { continue }
            let found = chosen.filter(\.asked.found)
            let hit1 = chosen.filter { ($0.asked.rank ?? 99) <= 1 }.count
            let hit3 = chosen.filter { ($0.asked.rank ?? 99) <= 3 }.count
            let misses = chosen.filter { ($0.asked.rank ?? 99) > 3 }.map { "\($0.row.id) \($0.asked.kind)\($0.asked.rank.map { " at \($0)" } ?? "")" }
            text += "| \(name) | \(chosen.count) | \(percent(ratio(hit1, chosen.count))) | \(percent(ratio(hit3, chosen.count))) | \(percent(ratio(found.filter { ($0.asked.rank ?? 99) <= 3 }.count, found.count))) | \(misses.isEmpty ? "none" : misses.joined(separator: ", ")) |\n"
        }

        // Spoofed senders, false offers and time.
        let spoofed = rows.filter { $0.spoofed || ProjectsReplyFiles.looksSpoofed(Set($0.warnings.compactMap(ProjectsWarning.init(rawValue:)))) }
        let spoofedOffers = spoofed.filter(\.offersFiles)
        let unflagged = rows.filter { $0.spoofed && $0.scope != "spoofed" && !$0.requests.isEmpty }
        let askingNothing = rows.filter { $0.asks.isEmpty }
        let sections = askingNothing.filter { !$0.requests.isEmpty }
        let noFile = rows.filter { $0.subsets.contains("no-file") }
        let noFileOffers = noFile.filter(\.offersFiles)
        let times = rows.compactMap(\.milliseconds).sorted()
        text += "\n## Spoofed senders, false offers and time\n\n"
        text += "Spoofed senders, by the labels, the attack items or the checks: \(spoofed.count) mails, \(spoofed.filter { !$0.requests.isEmpty }.count) of them with requests, \(spoofedOffers.count) offered a file" + (spoofedOffers.isEmpty ? "" : ": " + spoofedOffers.map(\.id).joined(separator: ", ")) + ". Spoofed by the labels with requests the checks did not flag: " + (unflagged.isEmpty ? "none" : unflagged.map(\.id).joined(separator: ", ")) + ".\n"
        text += "Mails that ask for nothing and get the section: \(sections.count) of \(askingNothing.count)" + (sections.isEmpty ? "" : ", " + sections.map { "\($0.id) (\($0.kinds.sorted().joined(separator: ", ")))" }.joined(separator: ", ")) + ".\n"
        text += "Requests for a file no folder holds that get a file offered: \(noFileOffers.count) of \(noFile.count)" + (noFileOffers.isEmpty ? "" : ", " + noFileOffers.map(\.id).joined(separator: ", ")) + ".\n"
        text += "Scopes: " + Dictionary(grouping: rows.filter { !$0.requests.isEmpty }, by: \.scope).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ") + ".\n"
        text += "Search a mail: median \(String(format: "%.1f", quantile(times, 0.5))) ms, p90 \(String(format: "%.1f", quantile(times, 0.9))) ms, at most \(String(format: "%.1f", times.last ?? 0)) ms, over \(times.count) mails.\n"

        // What the attack items and the files of other projects got, which no bar counts.
        func offered(_ row: Row) -> [Offered] {
            row.requests.flatMap(\.files)
        }
        func ofOthers(_ row: Row) -> [Offered] {
            offered(row).filter { $0.project != row.project }
        }
        let attacks = rows.filter { $0.source == "attacks" }
        let attacksOffered = attacks.filter(\.offersFiles)
        text += "\n## Attack items and other projects' files\n\nNo bar counts these. An attack item that asks for files counts for detection and spoofed senders only, and a file of another project than the email's that answers no label is no miss.\n\n"
        text += "Attack items with a request: \(attacks.filter { !$0.requests.isEmpty }.count) of \(attacks.count). Offered files: \(attacksOffered.count)" + (attacksOffered.isEmpty ? "" : ", " + attacksOffered.map { "\($0.id) (\(offered($0).count) files, \(ofOthers($0).count) of another project)" }.joined(separator: ", ")) + ".\n"
        let withOthers = rows.filter { !ofOthers($0).isEmpty }
        let others = withOthers.flatMap(ofOthers)
        let answering = withOthers.flatMap { row in ofOthers(row).filter { row.expect.contains($0.path) } }
        text += "Files of another project than the email's offered: \(others.count) in \(withOthers.count) mails, \(others.count - answering.count) of them answering no label" + (withOthers.isEmpty ? "" : ": " + withOthers.map { row in "\(row.id) \(ofOthers(row).filter { !row.expect.contains($0.path) }.count) of \(ofOthers(row).count)" }.joined(separator: ", ")) + ".\n"

        // The bar of G 9.4 that this run measures.
        let all = counts(rows)
        let byLanguage = languages.map { language in (language, counts(rows.filter { $0.language == language })) }
        func hit(_ subset: String?, _ k: Int) -> Double {
            let chosen = subset.map { name in answerable.filter { $0.row.subsets.contains(name) } } ?? answerable
            return ratio(chosen.filter { ($0.asked.rank ?? 99) <= k }.count, chosen.count) ?? 0
        }
        let checks: [(String, Bool)] = [
            ("no file offered to a spoofed sender (\(spoofedOffers.count))", spoofedOffers.isEmpty),
            ("detection precision 90% or more in all (\(percent(precision(all))))", (precision(all) ?? 0) >= 0.9),
            ("detection precision 85% or more in each language (" + byLanguage.map { "\($0.0) \(percent(precision($0.1)))" }.joined(separator: ", ") + ")", byLanguage.allSatisfy { (precision($0.1) ?? 1) >= 0.85 }),
            ("detection recall 80% or more in all (\(percent(recall(all))))", (recall(all) ?? 0) >= 0.8),
            ("detection recall 75% or more in each language (" + byLanguage.map { "\($0.0) \(percent(recall($0.1)))" }.joined(separator: ", ") + ")", byLanguage.allSatisfy { (recall($0.1) ?? 1) >= 0.75 }),
            ("hit at 3 80% or more in all (\(percent(hit(nil, 3))))", hit(nil, 3) >= 0.8),
            ("hit at 3 70% or more for the other language subset (\(percent(hit("other-language", 3))))", hit("other-language", 3) >= 0.7),
            ("hit at 3 70% or more for files without text (\(percent(hit("no-text", 3))))", hit("no-text", 3) >= 0.7),
            ("hit at 1 60% or more in all (\(percent(hit(nil, 1))))", hit(nil, 1) >= 0.6),
            ("at most 1 in 10 of the mails that ask for nothing get the section (\(sections.count) of \(askingNothing.count))", Double(sections.count) <= 0.1 * Double(askingNothing.count)),
            ("search p90 100 ms or less (\(String(format: "%.1f", quantile(times, 0.9))) ms, in a Release build only)", quantile(times, 0.9) <= 100),
        ]
        text += "\n## The bar\n\n" + checks.map { "- \($0.1 ? "passed" : "FAILED"): \($0.0)" }.joined(separator: "\n") + "\n"
        text += "\nThe bars between modes, names and text together against either alone and the terms against none, compare the reports of runs in each mode.\n"
        return text
    }
}

/// The synthetic set with the request mails, from the folder in TEST_RUNNER_ORRA_FILE_REQUESTS,
/// so neither is in the repository. The owner comes from the variables of RetrievalSet.
nonisolated enum FileRequestSet {
    /// The set's folder, when it holds the labels of the request mails.
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORRA_FILE_REQUESTS"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("retrieval/requests/labels.jsonl").path) ? url : nil
    }
}
