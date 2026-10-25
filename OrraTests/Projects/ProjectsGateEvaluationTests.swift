import AppKit
import CoreText
import Foundation
import Testing
@testable import Orra

/// Runs the 64 attack items of the synthetic Projects set through SortingService and
/// ExplainService with the real cleanup model, and writes what the user would see for the
/// projects suite of the release gate, which Tools/release-gate/gate.py scores. Only when
/// asked for, never in CI, and in a Release build, since a Debug build runs MLX without
/// optimization:
///
///     TEST_RUNNER_ORRA_PROJECTS_GATE=~/projects/orra-project/bench/projects-testset \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES=<work address>,<home address> \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_NAME=<name> \
///     TEST_RUNNER_ORRA_GATE_OUT=<folder> \
///     xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/ProjectsGateEvaluationTests
///
/// The user's addresses (comma separated) and name are those of the set's owner, from its
/// README, as the Debug override of the test guide gives them. They stay out of the
/// repository with the rest of the set. TEST_RUNNER_ORRA_PROJECTS_GATE_LANGUAGES is zh, en
/// or zh,en (the default), the languages of the explanations. Phase 0 tested only the
/// Chinese prompt. TEST_RUNNER_ORRA_PROJECTS_GATE_FIRST and TEST_RUNNER_ORRA_PROJECTS_GATE_COUNT
/// pick a part of the items, by their place in adversarial.jsonl from 1, so a long run goes
/// in parts. TEST_RUNNER_ORRA_PROJECTS_GATE_ATTACHMENTS=names reads attachments as names and
/// types only, as Orra did before it read their text, for a baseline from the same build.
///
/// Each item runs as phase 0 ran it, with today pinned to 2026-10-18, the day the labels
/// hold for:
/// - FolderIndex indexes the five project folders, which hold the five injected documents
///   of the set, so the document items need nothing placed.
/// - The item's last message is the email. Its earlier messages are its thread, filed in
///   the item's context project. A message with an HTML part reads as VisibleText reads
///   it, since Mail shows the richest part of multipart/alternative, and its hidden text
///   comes from there. A plain text message passes as it is, as projects-mail-text gives it.
/// - An attachment with text in the set becomes a file of its type, made by the test: a PDF
///   or a docx with the text, in white where the set marks white text, or the text itself
///   for csv, ics and other text. MailAttachment reads it as it reads an attachment in
///   Mail. Every other attachment is a name and a type.
/// - Sorting sees the 105 mails of mail.jsonl filed as their labels say, and the item's
///   earlier messages, and asks the model while the window is open.
/// - The explanation runs in the project sorting chose, sure or likely, and without one
///   otherwise. Its known people are the senders and recipients of earlier mail.
///
/// It writes projects-<first>-<last>.json into the gate folder, one row per item and
/// language, again after each item, so a run cut short keeps what it did. The rows hold
/// what the window would show: the project, the warnings, the points, the questions and
/// the checked draft, with what the draft check took out. The folder is outside the
/// repository, as the set is. The test prints counts only.
@Suite(.serialized, .enabled(if: GateAttackSet.folder != nil && !GateAttackSet.ownAddresses.isEmpty && !GateAttackSet.ownName.isEmpty && RewriteTestModel.folder != nil))
@MainActor
struct ProjectsGateEvaluationTests {
    /// Late on the day the labels hold for, after the last item, in the set's time zone.
    private nonisolated static let today = ISO8601DateFormatter().date(from: "2026-10-18T23:00:00+08:00")!
    private nonisolated static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    @Test func runTheAttackSet() async throws {
        let root = try #require(GateAttackSet.folder)
        let modelFolder = try #require(RewriteTestModel.folder)
        try #require(GateOutput.folder != nil, "TEST_RUNNER_ORRA_GATE_OUT names no folder for the results")
        let environment = ProcessInfo.processInfo.environment
        let languages = try Self.languages(environment["ORRA_PROJECTS_GATE_LANGUAGES"])
        let set = try GateAttackSet(root: root)
        let readsAttachments = environment["ORRA_PROJECTS_GATE_ATTACHMENTS"] != "names"
        let first = max(1, Int(environment["ORRA_PROJECTS_GATE_FIRST"] ?? "") ?? 1)
        let count = max(0, Int(environment["ORRA_PROJECTS_GATE_COUNT"] ?? "") ?? set.items.count)
        let chosen = Array(set.items.dropFirst(first - 1).prefix(count))
        try #require(!chosen.isEmpty, "no item from \(first)")
        let ownAddresses = GateAttackSet.ownAddresses
        let ownName = GateAttackSet.ownName
        let own = Set(ownAddresses)

        // The five folders, as FolderIndex keeps them. The index holds the set's text, so it
        // goes whichever way the run ends.
        let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsGateEvaluation-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let database = try await ProjectsDatabase.open(in: storage)
        let index = FolderIndex(database: database, isDictating: { false }, watch: { _, _, _ in {} })
        let indexStarted = ContinuousClock.now
        for project in set.projects {
            index.start(project: project.id, folders: [root.appendingPathComponent(project.folder, isDirectory: true)])
        }
        await index.waitUntilIdle()
        let indexTime = indexStarted.duration(to: .now)
        index.stopAll()
        var fileNames: [UUID: [String]] = [:]
        for row in try await database.run("SELECT project, path FROM index_files WHERE skip IS NULL") {
            guard let project = row[0].text.flatMap(UUID.init(uuidString:)), let path = row[1].text else { continue }
            fileNames[project, default: []].append((path as NSString).lastPathComponent)
        }
        let files = fileNames.values.map(\.count).reduce(0, +)
        let search = ChunkSearch(database: database)

        // The model, as the app runs it for Projects, one queue for sorting and explaining.
        let engine = CleanupEngine.live(RewriteEngine(), gate: ModelGate())
        try await engine.load(modelFolder)
        let counter = try await ProjectsTokenCounter.reading(modelFolder)
        let queue = ProjectsModelQueue(environment: ProjectsModelEnvironment(
            startJob: engine.startJob,
            readSlice: engine.readSlice,
            writeBurst: engine.writeBurst,
            endJob: engine.endJob,
            isDictating: { false },
            captionsOn: { false },
            memoryPressure: { .normal },
            voiceLoaded: { false },
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            waitUntilLoaded: { true },
            holdModel: {},
            releaseModel: {},
            sleep: { try await Task.sleep(for: $0) }
        ))

        // What every item's sorting reads: the 105 mails filed as labeled.
        var filed: [String: SortingService.Filed] = [:]
        var seenIn: [String: Set<UUID>] = [:]
        for mail in set.mails {
            let project = mail.labels?.project.flatMap { set.id(of: $0) }
            filed[GateAttackSet.bare(mail.message_id)] = SortingService.Filed(project: project)
            if let project {
                for address in GateAttackSet.addresses(of: mail) where !own.contains(address) {
                    seenIn[address, default: []].insert(project)
                }
            }
        }
        let candidates = set.projects.map { project in
            SortingCandidate(
                id: project.id, name: project.name, description: project.description,
                people: project.people.compactMap { person in
                    ProjectsAddress.normalized(person.address).map { SortingCandidate.Person(name: person.name, address: $0) }
                },
                domains: project.domains)
        }
        let scores: @Sendable (String) async -> [UUID: Double] = { text in (try? await search.projectScores(text)) ?? [:] }

        // One explain service per language, with lookups over the set.
        let context = GateAttackSet.Context(set: set, ownAddresses: ownAddresses, ownName: ownName)
        var promptTokens = 0
        var services: [ProjectsLanguage: ExplainService] = [:]
        for language in languages {
            services[language] = ExplainService(
                lookups: Self.lookups(context, search: search, database: database),
                run: { request in
                    promptTokens = counter.count(request.prompt)
                    return try await queue.run(request)
                },
                loadTokenCounter: { counter.count },
                save: { _ in },
                language: language,
                timeZone: Self.timeZone,
                now: { Self.today }
            )
        }

        let name = "projects-\(String(format: "%03d", first))-\(String(format: "%03d", first + chosen.count - 1))"
        var rows: [[String: Any]] = []
        var sortTimes: [Duration] = []
        var explainTimes: [Duration] = []
        var errors = 0
        var failure: (any Error)?
        do {
            for item in chosen {
                guard let message = item.messages.last else { continue }
                let earlier = Array(item.messages.dropLast())
                let contextProject = set.id(of: item.context_project)

                // Sorting, with the item's earlier messages filed in its context project.
                var itemFiled = filed
                var itemSeen = seenIn
                for other in earlier {
                    itemFiled[GateAttackSet.bare(other.message_id)] = SortingService.Filed(project: contextProject)
                    if let contextProject {
                        for address in GateAttackSet.addresses(of: other) where !own.contains(address) {
                            itemSeen[address, default: []].insert(contextProject)
                        }
                    }
                }
                let thread = earlier.map {
                    SortingService.ThreadMessage(messageID: GateAttackSet.bare($0.message_id), sender: $0.from, date: GateAttackSet.date($0.date))
                }
                var decision: SortingDecision?
                var model = "-"
                let sorter = SortingService(
                    lookups: SortingService.Lookups(
                        projects: { candidates },
                        owner: { SortingService.Owner(addresses: ownAddresses, name: ownName) },
                        fileNames: { fileNames[$0] ?? [] },
                        filed: { itemFiled[$0] },
                        peopleSeen: { addresses in
                            var found: [UUID: Set<String>] = [:]
                            for address in addresses {
                                for project in itemSeen[address] ?? [] {
                                    found[project, default: []].insert(address)
                                }
                            }
                            return found
                        },
                        thread: { _ in thread },
                        scores: scores,
                        waiting: { [] },
                        tally: { _, _ in nil }
                    ),
                    saves: SortingService.Saves(
                        decision: { _, saved in
                            decision = saved
                            return true
                        },
                        reply: { _, _ in },
                        move: { _, _ in },
                        tally: { _, _, _ in }
                    ),
                    windowIsOpen: { true },
                    ask: { request in
                        do {
                            let answer = try await queue.run(request)
                            model = Self.chosenName(answer)
                            return answer
                        } catch {
                            model = "error"
                            throw error
                        }
                    },
                    now: { Self.today }
                )
                let sortStarted = ContinuousClock.now
                await sorter.sort([GateAttackSet.sortingEmail(message)])
                let sortTime = sortStarted.duration(to: .now)
                sortTimes.append(sortTime)
                let placement = Self.placement(decision, set)
                let project: UUID? = switch decision?.level {
                case .sure, .likely: decision?.project
                default: nil
                }
                let sorting: [String: Any] = [
                    "id": item.id,
                    "placement": placement,
                    "level": decision?.level.rawValue ?? "missing",
                    "reasons": (decision?.reasons ?? []).map(\.rawValue),
                    "model": model,
                    "sort_seconds": GateOutput.seconds(sortTime),
                ]

                // The explanation in each language, in the project sorting chose.
                let email = await context.email(message, earlier: earlier, project: project, readsAttachments: readsAttachments)
                for language in languages {
                    guard let service = services[language] else { continue }
                    var row = sorting
                    row["language"] = language.rawValue
                    promptTokens = 0
                    let started = ContinuousClock.now
                    do {
                        let explanation = try await service.explain(email)
                        let time = started.duration(to: .now)
                        explainTimes.append(time)
                        row.merge(Self.row(explanation), uniquingKeysWith: { _, new in new })
                        row["seconds"] = GateOutput.seconds(time)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Counted, and gate.py fails the item. The kind only, never the text.
                        errors += 1
                        row["error"] = Self.errorName(error)
                    }
                    row["prompt_tokens"] = promptTokens
                    rows.append(row)
                }
                try GateOutput.write(Self.document(rows, first: first, count: chosen.count, languages: languages, indexTime: indexTime, files: files), named: name)
            }
        } catch {
            failure = error
        }
        await engine.unload()
        await database.close()
        if let failure { throw failure }

        // Counts and times only.
        print("Projects gate: \(chosen.count) items from \(first) in \(languages.map(\.rawValue).joined(separator: ", ")), \(files) files indexed in \(Self.seconds(indexTime)), sorting \(Self.seconds(Self.median(sortTimes))) and explaining \(Self.seconds(Self.median(explainTimes))) an item at the median, \(errors) errors. Rows in \(name).json.")
        #expect(files == 45, "the index holds \(files) files")
        #expect(errors == 0, "\(errors) explanations failed")
        #expect(rows.count == chosen.count * languages.count)
    }

    // MARK: The services

    private static func lookups(_ context: GateAttackSet.Context, search: ChunkSearch, database: ProjectsDatabase) -> ExplainService.Lookups {
        ExplainService.Lookups(
            known: { email in context.known(before: email) },
            thread: { email in context.thread(of: email) },
            projectMail: { query in context.projectMail(query) },
            search: { text, project, limit in try await search.search(text, in: [project], limit: limit) },
            newest: { project, limit in try await search.newest(project, limit: limit) },
            files: { project in
                try await database.run(
                    "SELECT f.path, f.modified, (SELECT c.text FROM index_chunks c WHERE c.file = f.id ORDER BY c.id LIMIT 1) FROM index_files f WHERE f.project = ? AND f.skip IS NULL",
                    [.text(project.uuidString)]
                ).compactMap { row in
                    guard row.count == 3, let path = row[0].text, let modified = row[1].real else { return nil }
                    return FileVersions.File(url: URL(fileURLWithPath: path), modified: Date(timeIntervalSince1970: modified), head: row[2].text ?? "")
                }
            }
        )
    }

    /// zh and en, in that order, from a comma separated list.
    private static func languages(_ value: String?) throws -> [ProjectsLanguage] {
        let names = (value ?? "zh,en").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let languages = [ProjectsLanguage.zh, .en].filter { names.contains($0.rawValue) }
        try #require(!languages.isEmpty && names.allSatisfy { $0 == "zh" || $0 == "en" }, "TEST_RUNNER_ORRA_PROJECTS_GATE_LANGUAGES must be zh, en or zh,en")
        return languages
    }

    /// The candidate name the model wrote, such as P1 or none, without its reason.
    private static func chosenName(_ answer: String) -> String {
        guard let object = RewritePrompt.answerObject(SortingPrompt.prefill + answer), let project = object["project"] as? String else {
            return "invalid"
        }
        return String(project.prefix(12))
    }

    /// Where a decision put the email: a slug, none for Set Aside, or needs for Needs a
    /// Project, as the set's labels name them.
    private static func placement(_ decision: SortingDecision?, _ set: GateAttackSet) -> String {
        guard let decision else { return "missing" }
        switch decision.level {
        case .sure, .likely: return set.slug(of: decision.project) ?? "none"
        case .setAside: return "none"
        case .unsure: return "needs"
        }
    }

    // MARK: The rows

    /// What the window shows of one explanation.
    private static func row(_ explanation: Explanation) -> [String: Any] {
        var row: [String: Any] = [
            "warnings": explanation.warningKinds.map(\.rawValue),
            "model_warnings": explanation.modelWarnings,
            "points": explanation.points.map(\.text),
            "questions": explanation.questions,
            "problems": explanation.problems.map { "\($0)" },
            "draft": NSNull(),
            "draft_language": NSNull(),
            "removals": [] as [[String: String]],
            "draft_flags": [] as [String],
        ]
        switch explanation.reply {
        case .reply(let language):
            row["reply"] = language.rawValue
        case .noReply(let reason):
            row["reply"] = "none"
            row["no_reply_reason"] = reason.rawValue
        }
        switch explanation.draft {
        case .checked(let result):
            row["draft_state"] = result.draft == nil ? "held_back" : "checked"
            row["draft"] = result.draft ?? NSNull()
            row["draft_language"] = result.language.rawValue
            row["removals"] = result.removals.map { ["kind": $0.kind.rawValue, "text": $0.text] }
            row["draft_flags"] = result.flags.map { "\($0)" }
        case .noReply:
            row["draft_state"] = "no_reply"
        case .noDraft:
            row["draft_state"] = "no_draft"
        case .missing:
            row["draft_state"] = "missing"
        case .expired:
            row["draft_state"] = "expired"
        }
        return row
    }

    private static func document(_ rows: [[String: Any]], first: Int, count: Int, languages: [ProjectsLanguage], indexTime: Duration, files: Int) -> [String: Any] {
        [
            "suite": "projects",
            "first": first,
            "count": count,
            "languages": languages.map(\.rawValue),
            "today": "2026-10-18",
            "files": files,
            "index_seconds": GateOutput.seconds(indexTime),
            "rows": rows,
        ]
    }

    /// The kind of error, never its description, which could hold text.
    private static func errorName(_ error: any Error) -> String {
        if let error = error as? RewriteError {
            return "RewriteError.\(error)"
        }
        return String(reflecting: type(of: error))
    }

    private static func median(_ times: [Duration]) -> Duration {
        let sorted = times.sorted()
        return sorted.isEmpty ? .zero : sorted[sorted.count / 2]
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", duration / .seconds(1))
    }
}

/// The attack set and the rest of the synthetic set, from the folder in
/// TEST_RUNNER_ORRA_PROJECTS_GATE, so none of it is in the repository.
nonisolated private struct GateAttackSet: Sendable {
    /// A message of mail.jsonl or of an attack item, as the set writes it.
    struct Message: Decodable, Sendable {
        struct Attachment: Decodable, Sendable {
            let name: String
            let type: String
            /// The attachment's text, in some attack items.
            let text: String?
        }

        struct Labels: Decodable, Sendable {
            let project: String?
        }

        let message_id: String
        let in_reply_to: String?
        let references: [String]?
        let date: String
        let from: String
        let to: [String]
        let cc: [String]?
        let subject: String
        let body: String
        let body_html: String?
        let attachments: [Attachment]?
        /// Only in mail.jsonl.
        let labels: Labels?
    }

    struct Item: Decodable, Sendable {
        let id: String
        let context_project: String
        let messages: [Message]
    }

    struct Project: Sendable {
        let id: UUID
        let slug: String
        let name: String
        let description: String
        let folder: String
        let people: [ExplainPrompt.Person]
        let domains: [String]
    }

    private struct SetProject: Decodable {
        let slug: String
        let name: String
        let description: String
        let folder: String
        let people: [String]
        let domains: [String]
    }

    /// The set's folder, when it holds the attack items.
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORRA_PROJECTS_GATE"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("adversarial.jsonl").path) ? url : nil
    }

    /// The owner's addresses in TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES, comma separated and
    /// normalized.
    static let ownAddresses: [String] = (ProcessInfo.processInfo.environment["ORRA_PROJECTS_OWN_ADDRESSES"] ?? "")
        .split(separator: ",")
        .compactMap { ProjectsAddress.normalized(String($0)) }

    /// The owner's name in TEST_RUNNER_ORRA_PROJECTS_OWN_NAME.
    static let ownName = ProcessInfo.processInfo.environment["ORRA_PROJECTS_OWN_NAME"] ?? ""

    let projects: [Project]
    let mails: [Message]
    let items: [Item]

    init(root: URL) throws {
        let decoder = JSONDecoder()
        let list = try decoder.decode([SetProject].self, from: Data(contentsOf: root.appendingPathComponent("projects/projects.json")))
        projects = list.enumerated().map { index, project in
            Project(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                slug: project.slug,
                name: project.name,
                description: project.description,
                folder: project.folder,
                people: project.people.map(Self.person),
                domains: project.domains)
        }
        mails = try Self.lines(root.appendingPathComponent("mail.jsonl")).map { try decoder.decode(Message.self, from: $0) }
        items = try Self.lines(root.appendingPathComponent("adversarial.jsonl")).map { try decoder.decode(Item.self, from: $0) }
    }

    func id(of slug: String) -> UUID? {
        projects.first { $0.slug == slug }?.id
    }

    func slug(of id: UUID?) -> String? {
        projects.first { $0.id == id }?.slug
    }

    private static func lines(_ url: URL) throws -> [Data] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { Data($0.utf8) }
    }

    // MARK: Messages

    static func bare(_ messageID: String) -> String {
        messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    static func person(_ value: String) -> ExplainPrompt.Person {
        let parsed = MailAddressHeader.list(value).first
        return ExplainPrompt.Person(name: parsed?.name ?? "", address: parsed?.address ?? value)
    }

    /// The sender's and the recipients' addresses, normalized.
    static func addresses(of message: Message) -> [String] {
        ([message.from] + message.to + (message.cc ?? [])).compactMap { ProjectsAddress.normalized(person($0).address) }
    }

    /// The text a reader sees and the kinds of text the message hides: an HTML part as
    /// VisibleText reads it, a plain text one as it is.
    static func visible(_ message: Message) -> (text: String, hidden: [ProjectsHiddenText]) {
        guard let html = message.body_html, !html.isEmpty else { return (message.body, []) }
        let visible = VisibleText(markup: html)
        return (visible.text, visible.findings)
    }

    /// The attachments as MailAttachment reads them from the parts of the message's source,
    /// as the scan does: a file made from each text, else an empty part, which keeps its name
    /// and type only. Without `readsText` they are names and types only, as Orra read them
    /// before.
    static func mailAttachments(_ message: Message, readsText: Bool) async -> [MailAttachment] {
        let attachments = message.attachments ?? []
        guard readsText else {
            return attachments.map { MailAttachment(name: $0.name, type: $0.type, state: .otherType) }
        }
        let files = attachments.map { attachment in
            let data = attachment.text.flatMap { file($0, name: attachment.name, type: attachment.type) }
            return AttachedFiles.File(name: attachment.name, type: attachment.type, data: data ?? Data())
        }
        return await MailAttachment.read(AttachedFiles.parts(files), modified: date(message.date))
    }

    /// A file of the attachment's type with the text: a PDF or a docx, in which a line that
    /// starts with "[white text]" is white without the mark, or the text in UTF-8 for any
    /// other type MailAttachment reads as text. Nil for another type.
    static func file(_ text: String, name: String, type: String) -> Data? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> (text: String, white: Bool) in
            let mark = "[white text] "
            return line.hasPrefix(mark) ? (String(line.dropFirst(mark.count)), true) : (String(line), false)
        }
        switch MailAttachment.format(name: name, type: type) {
        case .pdf?:
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
            var baseline: CGFloat = 740
            for line in lines {
                let drawn = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): line.white ? CGColor.white : CGColor.black,
                ]))
                context.textPosition = CGPoint(x: 40, y: baseline)
                CTLineDraw(drawn, context)
                baseline -= 18
            }
            context.endPDFPage()
            context.closePDF()
            return data as Data
        case .docx?:
            let document = NSMutableAttributedString()
            for line in lines {
                document.append(NSAttributedString(string: line.text + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: line.white ? NSColor.white : NSColor.black,
                ]))
            }
            return try? document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        case .text?:
            return Data(text.utf8)
        default:
            return nil
        }
    }

    /// The email as sorting gets it: its visible text without quoted history.
    static func sortingEmail(_ message: Message) -> SortingService.Email {
        SortingService.Email(
            messageID: bare(message.message_id),
            sender: message.from,
            recipients: message.to + (message.cc ?? []),
            date: date(message.date),
            subject: message.subject,
            text: QuotedHistory(splitting: visible(message).text).ownText,
            attachmentNames: (message.attachments ?? []).map(\.name),
            inReplyTo: message.in_reply_to.map { [bare($0)] } ?? [],
            references: (message.references ?? []).map(bare))
    }

    /// A message as the prompt shows it from the thread or the project's other mail.
    static func promptMail(_ message: Message) -> ExplainPrompt.Mail {
        ExplainPrompt.Mail(
            messageID: bare(message.message_id),
            date: date(message.date),
            sender: person(message.from),
            to: message.to.map(person),
            cc: (message.cc ?? []).map(person),
            subject: message.subject,
            attachmentNames: (message.attachments ?? []).map(\.name),
            text: QuotedHistory(splitting: visible(message).text).ownText)
    }

    // MARK: Lookups

    /// What the explain service's lookups read, for every item.
    struct Context: Sendable {
        let mails: [Message]
        let projects: [ExplainService.Project]
        let slugs: [UUID: String]
        let ownAddresses: [String]
        let ownName: String
        /// The earlier messages of each item, by the Message-ID of its last.
        let earlier: [String: [Message]]

        init(set: GateAttackSet, ownAddresses: [String], ownName: String) {
            mails = set.mails
            projects = set.projects.map {
                ExplainService.Project(id: $0.id, name: $0.name, description: $0.description, people: $0.people, domains: $0.domains)
            }
            slugs = Dictionary(uniqueKeysWithValues: set.projects.map { ($0.id, $0.slug) })
            self.ownAddresses = ownAddresses
            self.ownName = ownName
            var earlier: [String: [Message]] = [:]
            for item in set.items {
                guard let last = item.messages.last else { continue }
                earlier[GateAttackSet.bare(last.message_id)] = Array(item.messages.dropLast())
            }
            self.earlier = earlier
        }

        /// The email as projects-mail-text gives it: its own text without the quoted
        /// history when the message it answers is in its thread, and its attachments as
        /// MailAttachment reads them.
        func email(_ message: Message, earlier: [Message], project: UUID?, readsAttachments: Bool) async -> ExplainService.Email {
            let visible = GateAttackSet.visible(message)
            let parentKnown = message.in_reply_to.map { id in earlier.contains { GateAttackSet.bare($0.message_id) == GateAttackSet.bare(id) } } ?? false
            let split = QuotedHistory(splitting: visible.text)
            return ExplainService.Email(
                messageID: GateAttackSet.bare(message.message_id),
                date: GateAttackSet.date(message.date),
                sender: GateAttackSet.person(message.from),
                to: message.to.map(GateAttackSet.person),
                cc: (message.cc ?? []).map(GateAttackSet.person),
                subject: message.subject,
                attachments: await GateAttackSet.mailAttachments(message, readsText: readsAttachments),
                text: parentKnown && !split.quotedText.isEmpty ? split.ownText : visible.text,
                visibleText: visible.text,
                hiddenText: visible.hidden,
                project: project)
        }

        /// The user, the projects, and everyone on mail dated before the email, so a
        /// stranger's first email never makes its sender known.
        func known(before email: ExplainService.Email) -> ExplainService.Known {
            let before = mails.filter { GateAttackSet.date($0.date) < email.date } + (earlier[email.messageID] ?? [])
            let own = Set(ownAddresses)
            var correspondents: [SenderChecks.Person] = []
            var seen: Set<String> = []
            for mail in before {
                for value in [mail.from] + mail.to + (mail.cc ?? []) {
                    let person = GateAttackSet.person(value)
                    guard let address = ProjectsAddress.normalized(person.address), !own.contains(address), seen.insert(address).inserted else { continue }
                    correspondents.append(SenderChecks.Person(name: person.name, address: address))
                }
            }
            let sent = before.filter { ProjectsAddress.normalized(GateAttackSet.person($0.from).address).map(own.contains) ?? false }.map(\.body)
            return ExplainService.Known(ownName: ownName, ownAddresses: ownAddresses, projects: projects, correspondents: correspondents, sentTexts: sent)
        }

        func thread(of email: ExplainService.Email) -> [ExplainPrompt.Mail] {
            (earlier[email.messageID] ?? []).map(GateAttackSet.promptMail)
        }

        /// The project's mail in mail.jsonl, ranked by the words it shares with the query.
        func projectMail(_ query: ExplainService.MailQuery) -> [ExplainPrompt.Mail] {
            let slug = slugs[query.project]
            let words = Set(ChunkSearch.words(in: query.text).filter { $0.count > 1 })
            return mails
                .filter { $0.labels?.project == slug && !query.excluding.contains(GateAttackSet.bare($0.message_id)) }
                .map { mail in (mail, words.intersection(ChunkSearch.words(in: mail.subject + "\n" + mail.body)).count) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .prefix(query.limit)
                .map { GateAttackSet.promptMail($0.0) }
        }
    }
}
