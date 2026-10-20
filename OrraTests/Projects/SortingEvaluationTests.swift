import Foundation
import Testing
@testable import Orra

/// Sorts the 105 mails of the synthetic set of phase 0 with SortingService, the real full
/// text index of the five project folders and the real cleanup model. Only when asked for,
/// never in CI, in a Release build, since a Debug build runs MLX without optimization:
///
///     TEST_RUNNER_ORRA_PROJECTS_SET=~/projects/orra-project/bench/projects-testset TEST_RUNNER_ORRA_PROJECTS_SORT_OUT=<folder> xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/SortingEvaluationTests
///
/// As in phase 0, each mail sees the earlier mails filed as their labels say (gold
/// history), so each number is one decision, and today is 2026-10-18, the day the labels
/// hold for. The user's addresses and name are those of the set's owner, as the Debug
/// override of the test guide gives them. The mails have no list headers, as in phase 0.
///
/// A mail is right when it lands in its project, or in Set Aside when its label is none.
/// Needs a Project counts apart, and anything else is wrong. The bar of the plan: at least
/// 88 right and at most 6 wrong of 105 (phase 0: 91 right, 10 in Needs a Project, 4 wrong).
///
/// With TEST_RUNNER_ORRA_PROJECTS_SORT_PHASE0 set to a JSON lines file of the phase 0
/// decisions, `{"id": "m001", "project": "<slug>", "none" or null}`, the report lists every
/// mail where this run differs from phase 0. The report holds ids, project slugs, levels,
/// reasons and the model's choices, never mail text, addresses or names.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_PROJECTS_SET"] != nil && RewriteTestModel.folder != nil))
@MainActor
struct SortingEvaluationTests {
    static var setFolder: URL? {
        ProcessInfo.processInfo.environment["ORRA_PROJECTS_SET"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// The day the labels hold for, noon in the set's time zone.
    nonisolated static let today = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00+08:00")!
    nonisolated static let ownAddresses = ["lin.zhou@qingshi.example", "linzhou@mailbox.example"]
    nonisolated static let ownName = "林舟"
    nonisolated static let bar = (right: 88, wrong: 6)

    @Test func sortTheSyntheticSet() async throws {
        let root = try #require(Self.setFolder)
        let modelFolder = try #require(RewriteTestModel.folder)
        let set = try SyntheticSet(root: root)
        try #require(set.mails.count == 105)

        // The index of the five folders, as FolderIndex keeps it.
        let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SortingEvaluation-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let database = try await ProjectsDatabase.open(in: storage)
        let index = FolderIndex(database: database, isDictating: { false }, watch: { _, _, _ in {} })
        let indexStarted = ContinuousClock.now
        for project in set.projects {
            index.start(project: project.candidate.id, folders: [root.appendingPathComponent(project.folder, isDirectory: true)])
        }
        await index.waitUntilIdle()
        let indexTime = indexStarted.duration(to: .now)
        index.stopAll()
        var fileNames: [UUID: [String]] = [:]
        for row in try await database.run("SELECT project, path FROM index_files WHERE skip IS NULL") {
            guard let project = row[0].text.flatMap(UUID.init(uuidString:)), let path = row[1].text else { continue }
            fileNames[project, default: []].append((path as NSString).lastPathComponent)
        }
        try #require(fileNames.values.map(\.count).reduce(0, +) == 45, "the index holds \(fileNames.values.map(\.count).reduce(0, +)) files")
        let search = ChunkSearch(database: database)
        let scores: @Sendable (String) async -> [UUID: Double] = { text in (try? await search.projectScores(text)) ?? [:] }

        // The rules alone, then the rules with the model.
        let rules = await Self.sort(set, fileNames: fileNames, scores: scores, ask: nil)
        let engine = RewriteEngine()
        try await engine.load(from: modelFolder)
        let queue = Self.queue(engine)
        var chosen: [String] = []
        let modelStarted = ContinuousClock.now
        let model = await Self.sort(set, fileNames: fileNames, scores: scores) { request in
            let answer = try await queue.run(request)
            chosen.append(Self.chosenName(answer))
            return answer
        }
        let modelTime = modelStarted.duration(to: .now)
        await engine.unload()
        await database.close()

        let phase0 = try Self.phase0()
        let report = Self.report(
            set, rules: rules, model: model, chosen: chosen, phase0: phase0,
            indexTime: indexTime, modelTime: modelTime, files: fileNames.values.map(\.count).reduce(0, +))
        try Self.write(report.text, named: "sorting.md")
        try Self.write(report.rows, named: "sorting.jsonl")
        #expect(report.right >= Self.bar.right, "\(report.right) right")
        #expect(report.wrong <= Self.bar.wrong, "\(report.wrong) wrong")
    }

    // MARK: The run

    /// What one run saved for each mail.
    struct Run {
        var decisions: [String: SortingDecision] = [:]
        var replies: [String: ReplyRule.Decision] = [:]
        /// The mails the model was asked about, by set id, in order.
        var asked: [String] = []
    }

    /// Sorts the mails in date order, each after the earlier ones were filed as labeled.
    /// Without `ask` the window stays closed, so the rules decide alone.
    private static func sort(
        _ set: SyntheticSet,
        fileNames: [UUID: [String]],
        scores: @escaping @Sendable (String) async -> [UUID: Double],
        ask: ((ProjectsModelRequest) async throws -> String)?
    ) async -> Run {
        let history = GoldHistory(set: set)
        var run = Run()
        var current = ""
        let lookups = SortingService.Lookups(
            projects: { set.projects.map(\.candidate) },
            owner: { SortingService.Owner(addresses: ownAddresses, name: ownName) },
            fileNames: { fileNames[$0] ?? [] },
            filed: { history.filed[$0] },
            peopleSeen: { history.seen(among: $0) },
            thread: { history.thread(of: $0.messageID) },
            scores: scores,
            waiting: { [] },
            tally: { _, _ in nil }
        )
        let saves = SortingService.Saves(
            decision: { id, decision in run.decisions[set.id(of: id)] = decision },
            reply: { id, decision in run.replies[set.id(of: id)] = decision },
            move: { _, _ in },
            tally: { _, _, _ in }
        )
        let service = SortingService(
            lookups: lookups, saves: saves,
            windowIsOpen: { ask != nil },
            ask: { request in
                run.asked.append(current)
                guard let ask else { throw RewriteError.notLoaded }
                return try await ask(request)
            },
            now: { today })
        for mail in set.mails {
            current = mail.id
            await service.sort([mail.email])
            history.file(mail)
        }
        return run
    }

    /// The queue on the engine, with nothing to wait for.
    private static func queue(_ engine: RewriteEngine) -> ProjectsModelQueue {
        let jobs = CleanupEngine.live(engine, gate: ModelGate())
        return ProjectsModelQueue(environment: ProjectsModelEnvironment(
            startJob: jobs.startJob,
            readSlice: jobs.readSlice,
            writeBurst: jobs.writeBurst,
            endJob: jobs.endJob,
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
    }

    /// The candidate name the model wrote, such as P1 or none, without its reason.
    private static func chosenName(_ answer: String) -> String {
        guard let object = RewritePrompt.answerObject(SortingPrompt.prefill + answer), let project = object["project"] as? String else {
            return "invalid"
        }
        return String(project.prefix(12))
    }

    // MARK: The set

    /// The projects and mails of the synthetic set.
    struct SyntheticSet {
        struct Project {
            var slug: String
            var folder: String
            var candidate: SortingCandidate
        }

        struct Mail {
            var id: String
            var thread: String
            /// The slug, or none.
            var gold: String
            var needsReply: Bool
            var kinds: [String]
            var addresses: [String]
            var email: SortingService.Email
        }

        var projects: [Project] = []
        var mails: [Mail] = []
        private var ids: [String: String] = [:]

        init(root: URL) throws {
            let list = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("projects/projects.json"))) as? [[String: Any]] ?? []
            for item in list {
                let people = (item["people"] as? [String] ?? []).compactMap { entry -> SortingCandidate.Person? in
                    guard let address = ProjectsAddress.normalized(entry) else { return nil }
                    let name = entry.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    return SortingCandidate.Person(name: name, address: address)
                }
                let candidate = SortingCandidate(
                    id: UUID(), name: item["name"] as? String ?? "", description: item["description"] as? String ?? "",
                    people: people, domains: item["domains"] as? [String] ?? [])
                projects.append(Project(slug: item["slug"] as? String ?? "", folder: item["folder"] as? String ?? "", candidate: candidate))
            }
            let dates = ISO8601DateFormatter()
            let lines = try String(contentsOf: root.appendingPathComponent("mail.jsonl"), encoding: .utf8).split(separator: "\n")
            for line in lines {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = object["id"] as? String, let date = (object["date"] as? String).flatMap(dates.date(from:)),
                      let labels = object["labels"] as? [String: Any] else { continue }
                let from = object["from"] as? String ?? ""
                let recipients = (object["to"] as? [String] ?? []) + (object["cc"] as? [String] ?? [])
                let messageID = Self.bare(object["message_id"] as? String ?? id)
                let email = SortingService.Email(
                    messageID: messageID,
                    sender: from,
                    recipients: recipients,
                    date: date,
                    subject: object["subject"] as? String ?? "",
                    text: QuotedHistory(splitting: object["body"] as? String ?? "").ownText,
                    attachmentNames: (object["attachments"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                    inReplyTo: (object["in_reply_to"] as? String).map { [Self.bare($0)] } ?? [],
                    references: (object["references"] as? [String] ?? []).map(Self.bare))
                mails.append(Mail(
                    id: id, thread: object["thread"] as? String ?? id, gold: labels["project"] as? String ?? "none",
                    needsReply: labels["needs_reply"] as? Bool ?? false, kinds: labels["kinds"] as? [String] ?? [],
                    addresses: ([from] + recipients).compactMap(ProjectsAddress.normalized), email: email))
                ids[messageID] = id
            }
        }

        func project(_ slug: String) -> UUID? {
            projects.first { $0.slug == slug }?.candidate.id
        }

        func slug(_ project: UUID?) -> String {
            projects.first { $0.candidate.id == project }?.slug ?? "none"
        }

        /// The set's id of a Message-ID.
        func id(of messageID: String) -> String {
            ids[messageID] ?? messageID
        }

        private static func bare(_ id: String) -> String {
            id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        }
    }

    /// The mails filed so far, as their labels say.
    final class GoldHistory {
        let set: SyntheticSet
        private(set) var filed: [String: SortingService.Filed] = [:]
        private var seenIn: [String: Set<UUID>] = [:]
        private var threads: [String: [SyntheticSet.Mail]] = [:]
        private var threadOf: [String: String] = [:]

        init(set: SyntheticSet) {
            self.set = set
            for mail in set.mails {
                threadOf[mail.email.messageID] = mail.thread
            }
        }

        func file(_ mail: SyntheticSet.Mail) {
            let project = set.project(mail.gold)
            filed[mail.email.messageID] = SortingService.Filed(project: project)
            if let project {
                for address in mail.addresses where !SortingEvaluationTests.ownAddresses.contains(address) {
                    seenIn[address, default: []].insert(project)
                }
            }
            threads[mail.thread, default: []].append(mail)
        }

        func seen(among addresses: [String]) -> [UUID: Set<String>] {
            var found: [UUID: Set<String>] = [:]
            for address in addresses {
                for project in seenIn[address] ?? [] {
                    found[project, default: []].insert(address)
                }
            }
            return found
        }

        func thread(of messageID: String) -> [SortingService.ThreadMessage] {
            guard let thread = threadOf[messageID] else { return [] }
            return (threads[thread] ?? []).filter { $0.email.messageID != messageID }.map {
                SortingService.ThreadMessage(messageID: $0.email.messageID, sender: $0.email.sender, date: $0.email.date)
            }
        }
    }

    // MARK: The report

    private enum Outcome: String {
        case right, needs, wrong
    }

    /// Where a decision put the mail: a slug, none for Set Aside, or needs for Needs a
    /// Project.
    private static func placement(_ decision: SortingDecision?, _ set: SyntheticSet) -> String {
        guard let decision else { return "missing" }
        switch decision.level {
        case .sure, .likely: return set.slug(decision.project)
        case .setAside: return "none"
        case .unsure: return "needs"
        }
    }

    private static func outcome(_ placement: String, gold: String) -> Outcome {
        placement == "needs" ? .needs : (placement == gold ? .right : .wrong)
    }

    /// The phase 0 decisions, by id, when TEST_RUNNER_ORRA_PROJECTS_SORT_PHASE0 names them.
    private static func phase0() throws -> [String: String] {
        guard let path = ProcessInfo.processInfo.environment["ORRA_PROJECTS_SORT_PHASE0"] else { return [:] }
        var decisions: [String: String] = [:]
        for line in try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = object["id"] as? String else { continue }
            decisions[id] = (object["project"] as? String) ?? "needs"
        }
        return decisions
    }

    private static func report(
        _ set: SyntheticSet, rules: Run, model: Run, chosen: [String], phase0: [String: String],
        indexTime: Duration, modelTime: Duration, files: Int
    ) -> (text: String, rows: String, right: Int, wrong: Int) {
        var counts: [Outcome: Int] = [:]
        var rulesCounts: [Outcome: Int] = [:]
        var phase0Counts: [Outcome: Int] = [:]
        var lines: [String] = []
        var differences: [String] = []
        var rows: [String] = []
        var replyRight = 0
        var choice: [String: String] = [:]
        for (id, name) in zip(model.asked, chosen) {
            choice[id] = name
        }
        for mail in set.mails {
            let now = placement(model.decisions[mail.id], set)
            let alone = placement(rules.decisions[mail.id], set)
            let result = outcome(now, gold: mail.gold)
            counts[result, default: 0] += 1
            rulesCounts[outcome(alone, gold: mail.gold), default: 0] += 1
            let reasons = (model.decisions[mail.id]?.reasons ?? []).map(\.rawValue).joined(separator: ",")
            let asked = choice[mail.id] ?? "-"
            if result != .right {
                lines.append("- \(mail.id): \(mail.gold) went to \(now) (\(model.decisions[mail.id]?.level.rawValue ?? "missing"), \(reasons)), the rules alone: \(alone), the model: \(asked). Kinds: \(mail.kinds.joined(separator: ", "))")
            }
            if let before = phase0[mail.id] {
                phase0Counts[outcome(before, gold: mail.gold), default: 0] += 1
                if before != now {
                    differences.append("- \(mail.id): \(mail.gold). Phase 0 \(before), now \(now) (\(reasons)), the rules alone now \(alone), the model: \(asked). Kinds: \(mail.kinds.joined(separator: ", "))")
                }
            }
            let reply = model.replies[mail.id]
            let replyDue: Bool? = reply.map {
                if case .reply = $0 { return true }
                return false
            }
            if replyDue == mail.needsReply {
                replyRight += 1
            }
            let row: [String: Any] = [
                "id": mail.id, "gold": mail.gold, "placement": now, "outcome": result.rawValue,
                "level": model.decisions[mail.id]?.level.rawValue ?? "missing", "reasons": reasons,
                "rules_alone": alone, "model": asked, "phase0": phase0[mail.id] ?? "",
                "reply_due": replyDue.map { $0 ? "yes" : "no" } ?? "missing", "needs_reply": mail.needsReply,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
                rows.append(text)
            }
        }
        let invalid = chosen.filter { $0 == "invalid" }.count
        var text = """
            # Sorting the synthetic set, chip \(SpeechCorpus.chip())

            Today pinned to 2026-10-18, gold history, \(set.mails.count) mails, \(files) files indexed in \(seconds(indexTime)).

            | Run | Right | Needs a Project | Wrong |
            |---|---|---|---|
            | Rules alone (window closed) | \(rulesCounts[.right] ?? 0) | \(rulesCounts[.needs] ?? 0) | \(rulesCounts[.wrong] ?? 0) |
            | Rules and the model | \(counts[.right] ?? 0) | \(counts[.needs] ?? 0) | \(counts[.wrong] ?? 0) |

            """
        if !phase0.isEmpty {
            text += "| Phase 0, rules and the 4B, its none to Needs a Project | \(phase0Counts[.right] ?? 0) | \(phase0Counts[.needs] ?? 0) | \(phase0Counts[.wrong] ?? 0) |\n"
        }
        text += """

            The bar: at least \(bar.right) right and at most \(bar.wrong) wrong.

            The model was asked about \(model.asked.count) mails in \(seconds(modelTime)) with the run's other work, and \(invalid) answers were invalid. The reply due mark matches needs_reply for \(replyRight) of \(set.mails.count) mails.

            ## Not right

            \(lines.joined(separator: "\n"))

            """
        if !phase0.isEmpty {
            text += """

                ## Different from phase 0 (\(differences.count))

                \(differences.joined(separator: "\n"))

                """
        }
        return (text, rows.joined(separator: "\n") + "\n", counts[.right] ?? 0, counts[.wrong] ?? 0)
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", duration / .seconds(1))
    }

    /// Prints the text, attaches it to the result and writes it to the folder in
    /// TEST_RUNNER_ORRA_PROJECTS_SORT_OUT, when set.
    private static func write(_ text: String, named name: String) throws {
        print(text)
        Attachment.record(text, named: name)
        if let folder = ProcessInfo.processInfo.environment["ORRA_PROJECTS_SORT_OUT"] {
            try text.write(toFile: (folder as NSString).expandingTildeInPath + "/" + name, atomically: true, encoding: .utf8)
        }
    }
}
