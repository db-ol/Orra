import Foundation
import Testing
@testable import Orra

/// Suggested Projects on the 105 mails of the synthetic set of phase 0, with no project
/// set up, as when the maintainer first imported it and every mail sat in Needs a Project.
/// Only when asked for, never in CI, in a Release build, since a Debug build runs MLX
/// without optimization:
///
///     TEST_RUNNER_ORRA_PROJECTS_SET=~/projects/orra-project/bench/projects-testset \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES=<work address>,<home address> \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_NAME=<name> \
///     TEST_RUNNER_ORRA_PROJECTS_SUGGEST_OUT=<folder> \
///     xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/ProjectSuggestionsEvaluationTests
///
/// The user's addresses and name are those of the set's owner, from its README, as the
/// Debug override of the test guide gives them. The mails have no list headers and come
/// from one mailbox, as in the maintainer's import.
///
/// It groups the mail with SuggestionService, which names the groups with the real cleanup
/// model through ProjectsModelQueue, as the window does. With
/// TEST_RUNNER_ORRA_PROJECTS_SUGGEST_MODEL=0, or without the model, the groups keep their
/// names in code. Then it creates every suggestion as New Project is prefilled from it and
/// sorts all the mail again with SortingService, by the rules alone and with the model, as
/// the window does after a project is created.
///
/// Each suggestion is scored against the set's labels: the project most of the emails it
/// would take carry, and how many of them carry it. A project of projects.json is found
/// when a suggestion takes at least 3 of its emails and at least `foundShare` of the emails
/// that suggestion takes are of it. The report holds the set's ids, project slugs, counts,
/// and the names and descriptions the model wrote for the synthetic mail.
@Suite(.serialized, .enabled(if: ["ORRA_PROJECTS_SET", "ORRA_PROJECTS_OWN_ADDRESSES", "ORRA_PROJECTS_OWN_NAME"].allSatisfy { ProcessInfo.processInfo.environment[$0] != nil }))
@MainActor
struct ProjectSuggestionsEvaluationTests {
    static var setFolder: URL? {
        ProcessInfo.processInfo.environment["ORRA_PROJECTS_SET"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    nonisolated static let ownAddresses = (ProcessInfo.processInfo.environment["ORRA_PROJECTS_OWN_ADDRESSES"] ?? "")
        .split(separator: ",").compactMap { ProjectsAddress.normalized(String($0)) }
    nonisolated static let ownName = ProcessInfo.processInfo.environment["ORRA_PROJECTS_OWN_NAME"]
    /// The day the labels hold for, noon in the set's time zone.
    nonisolated static let today = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00+08:00")!
    /// The share of a suggestion's emails that must be of one project for it to find that
    /// project.
    nonisolated static let foundShare = 0.75
    /// The projects of the set the suggestions must find.
    nonisolated static let bar = 5

    @Test func suggestProjectsForTheSyntheticSet() async throws {
        let root = try #require(Self.setFolder)
        let set = try SyntheticSet(root: root)
        try #require(set.mails.count == 105)
        try #require(!Self.ownAddresses.isEmpty, "TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES holds no address")

        let useModel = ProcessInfo.processInfo.environment["ORRA_PROJECTS_SUGGEST_MODEL"] != "0" && RewriteTestModel.folder != nil
        var engine: RewriteEngine?
        var queue: ProjectsModelQueue?
        if useModel, let folder = RewriteTestModel.folder {
            let loaded = RewriteEngine()
            try await loaded.load(from: folder)
            engine = loaded
            queue = Self.queue(loaded)
        }
        let owner = SortingService.Owner(addresses: Self.ownAddresses, name: Self.ownName)
        let service = SuggestionService(
            lookups: SuggestionService.Lookups(
                mail: { set.suggestionMail },
                projects: { [] },
                owner: { owner },
                dismissed: { [] }
            ),
            ask: { request in
                guard let queue else { throw RewriteError.notLoaded }
                return try await queue.run(request)
            },
            windowIsOpen: { true })
        let started = ContinuousClock.now
        await service.refresh()
        await service.untilNamed()
        let suggestTime = started.duration(to: .now)
        let groups = await ProjectSuggestions.groups(in: set.suggestionMail, ownAddresses: Self.ownAddresses, projects: [], dismissed: [])

        // Every suggestion created as prefilled, then all the mail sorted again.
        var created: [(suggestion: SuggestionService.Suggestion, project: SortingCandidate)] = []
        for suggestion in service.suggestions {
            var draft = ProjectsSetupView.Draft(suggestion: suggestion)
            draft.folders = []
            let project = try #require(draft.project, "the prefilled \(suggestion.id) is not valid")
            created.append((suggestion, project.candidate))
        }
        let rules = await Self.sort(set, projects: created.map(\.project), ask: nil)
        let model = await Self.sort(set, projects: created.map(\.project), ask: queue.map { queue in { try await queue.run($0) } })
        await engine?.unload()

        let report = Self.report(set, groups: groups, created: created, rules: rules, model: model, usedModel: useModel, time: suggestTime)
        try Self.write(report.text, named: "suggestions.md")
        #expect(report.found.count >= Self.bar, "found \(report.found.sorted())")
    }

    // MARK: Sorting after the projects are created

    /// Sorts every mail of the set in date order in one batch, as the window sorts Needs a
    /// Project again after a project is created, with what was filed so far as the history.
    private static func sort(_ set: SyntheticSet, projects: [SortingCandidate], ask: ((ProjectsModelRequest) async throws -> String)?) async -> [String: SortingDecision] {
        final class History {
            var decisions: [String: SortingDecision] = [:]
        }
        let history = History()
        let byMessageID = Dictionary(set.mails.map { ($0.email.messageID, $0) }, uniquingKeysWith: { first, _ in first })
        let lookups = SortingService.Lookups(
            projects: { projects },
            owner: { SortingService.Owner(addresses: ownAddresses, name: ownName) },
            fileNames: { _ in [] },
            filed: { id in
                guard let mail = byMessageID[id], let decision = history.decisions[mail.id] else { return nil }
                return SortingService.Filed(project: decision.project)
            },
            peopleSeen: { addresses in
                var seen: [UUID: Set<String>] = [:]
                for mail in set.mails {
                    guard let project = history.decisions[mail.id]?.project else { continue }
                    for address in mail.addresses where addresses.contains(address) {
                        seen[project, default: []].insert(address)
                    }
                }
                return seen
            },
            thread: { email in
                guard let thread = byMessageID[email.messageID]?.thread else { return [] }
                return set.mails.filter { $0.thread == thread && $0.email.messageID != email.messageID && history.decisions[$0.id] != nil }
                    .map { SortingService.ThreadMessage(messageID: $0.email.messageID, sender: $0.email.sender, date: $0.email.date) }
            },
            scores: { _ in [:] },
            waiting: { [] },
            tally: { _, _ in nil })
        let saves = SortingService.Saves(
            decision: { id, decision in
                history.decisions[byMessageID[id]?.id ?? id] = decision
                return true
            },
            reply: { _, _ in },
            move: { _, _ in },
            tally: { _, _, _ in })
        let service = SortingService(
            lookups: lookups, saves: saves,
            windowIsOpen: { ask != nil },
            ask: { request in
                guard let ask else { throw RewriteError.notLoaded }
                return try await ask(request)
            },
            now: { today })
        await service.sort(set.mails.map(\.email))
        return history.decisions
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

    // MARK: The set

    /// The mails of the synthetic set with their labels, as Suggested Projects and sorting
    /// read them.
    struct SyntheticSet {
        struct Mail {
            var id: String
            var thread: String
            /// The slug, or none.
            var gold: String
            var addresses: [String]
            var email: SortingService.Email
        }

        var slugs: [String] = []
        var mails: [Mail] = []
        var suggestionMail: [ProjectSuggestions.Mail] = []
        /// The set's id of each Message-ID.
        var ids: [String: String] = [:]

        init(root: URL) throws {
            let list = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("projects/projects.json"))) as? [[String: Any]] ?? []
            slugs = list.compactMap { $0["slug"] as? String }
            let dates = ISO8601DateFormatter()
            var threading: [MailThreads.Message] = []
            for line in try String(contentsOf: root.appendingPathComponent("mail.jsonl"), encoding: .utf8).split(separator: "\n") {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = object["id"] as? String, let date = (object["date"] as? String).flatMap(dates.date(from:)),
                      let labels = object["labels"] as? [String: Any] else { continue }
                let from = object["from"] as? String ?? ""
                let recipients = (object["to"] as? [String] ?? []) + (object["cc"] as? [String] ?? [])
                let messageID = Self.bare(object["message_id"] as? String ?? id)
                let inReplyTo = (object["in_reply_to"] as? String).map { [Self.bare($0)] } ?? []
                let references = (object["references"] as? [String] ?? []).map(Self.bare)
                let subject = object["subject"] as? String ?? ""
                let text = QuotedHistory(splitting: object["body"] as? String ?? "").ownText
                let attachments = (object["attachments"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                let addresses = ([from] + recipients).compactMap(ProjectsAddress.normalized)
                mails.append(Mail(
                    id: id, thread: object["thread"] as? String ?? id, gold: labels["project"] as? String ?? "none",
                    addresses: addresses,
                    email: SortingService.Email(
                        messageID: messageID, sender: from, recipients: recipients, date: date, subject: subject, text: text,
                        attachmentNames: attachments, inReplyTo: inReplyTo, references: references)))
                suggestionMail.append(ProjectSuggestions.Mail(
                    messageID: messageID, date: date, sender: Self.person(from), recipients: recipients.map(Self.person),
                    subject: subject, text: String(text.prefix(SuggestionPrompt.textLimit * 4)), attachmentNames: attachments,
                    mailbox: "/Import/orra-test", inReplyTo: inReplyTo, references: references, threadRoot: messageID))
                threading.append(MailThreads.Message(
                    messageID: messageID, inReplyTo: inReplyTo, references: references, subject: subject,
                    people: Set(addresses), date: date))
                ids[messageID] = id
            }
            // The roots the store would find, which it keeps for each email.
            let roots = MailThreads.roots(of: threading, ownAddresses: Set(ProjectSuggestionsEvaluationTests.ownAddresses))
            for index in suggestionMail.indices {
                suggestionMail[index].threadRoot = roots[suggestionMail[index].messageID] ?? suggestionMail[index].messageID
            }
            // Newest first, as the store gives them.
            suggestionMail.sort { $0.date > $1.date }
        }

        func gold(_ messageID: String) -> String {
            ids[messageID].flatMap { id in mails.first { $0.id == id }?.gold } ?? "missing"
        }

        private static func person(_ header: String) -> ProjectSuggestions.Person {
            let address = ProjectsAddress.normalized(header) ?? header
            let name = header.contains("<") ? header.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" : ""
            return ProjectSuggestions.Person(name: name, address: address)
        }

        private static func bare(_ id: String) -> String {
            id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        }
    }

    // MARK: The report

    /// The project most of the emails carry, how many do, and the share.
    private static func majority(_ golds: [String]) -> (slug: String, count: Int, share: Double) {
        var counts: [String: Int] = [:]
        for gold in golds {
            counts[gold, default: 0] += 1
        }
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return ("-", 0, 0) }
        return (best.key, best.value, Double(best.value) / Double(golds.count))
    }

    private static func report(
        _ set: SyntheticSet,
        groups: [ProjectSuggestions.Group],
        created: [(suggestion: SuggestionService.Suggestion, project: SortingCandidate)],
        rules: [String: SortingDecision],
        model: [String: SortingDecision],
        usedModel: Bool,
        time: Duration
    ) -> (text: String, found: Set<String>) {
        var totals: [String: Int] = [:]
        for mail in set.mails {
            totals[mail.gold, default: 0] += 1
        }
        var found = Set<String>()
        var lines: [String] = []
        for group in groups {
            let shown = created.first { $0.suggestion.id == group.id }?.suggestion
            let golds = group.takes.map(set.gold)
            let best = majority(golds)
            let others = zip(group.takes, golds).filter { $0.1 != best.slug }.map { "\(set.ids[$0.0] ?? "?") \($0.1)" }
            let isFound = shown != nil && best.slug != "none" && best.count >= 3 && best.share >= foundShare
            if isFound {
                found.insert(best.slug)
            }
            let name = shown.map { $0.isNamed ? $0.name : "(name in code) " + $0.name } ?? "(the model said none, not shown)"
            lines.append("""
                | \(name) | \(shown?.description ?? "") | \(group.anchor.key) | \(group.language.rawValue) | \(group.people.count) | \(group.domains.joined(separator: ", ")) | \(group.messageIDs.count) | \(group.takes.count) | \(best.slug) \(best.count) of \(totals[best.slug] ?? 0) | \(Int((best.share * 100).rounded())) % | \(others.joined(separator: ", ")) | \(isFound ? "yes" : "no") |
                """)
        }
        var sorted: [String] = []
        for (run, decisions) in [("Rules alone", rules), ("Rules and the model", model)] {
            for (suggestion, project) in created {
                let filed = set.mails.filter { decisions[$0.id]?.project == project.id }
                let best = majority(filed.map(\.gold))
                let sure = filed.filter { decisions[$0.id]?.level == .sure }.count
                sorted.append("| \(run) | \(suggestion.name) | \(filed.count) | \(sure) | \(best.slug) | \(best.count) of \(totals[best.slug] ?? 0) | \(filed.count - best.count) |")
            }
            let needs = set.mails.filter { decisions[$0.id]?.level == .unsure || decisions[$0.id] == nil }.count
            let aside = set.mails.filter { decisions[$0.id]?.level == .setAside }.count
            sorted.append("| \(run) | Needs a Project | \(needs) | | | | |")
            sorted.append("| \(run) | Set Aside | \(aside) | | | | |")
        }
        let missing = set.slugs.filter { !found.contains($0) }
        let text = """
            # Suggested Projects on the synthetic set, chip \(SpeechCorpus.chip())

            \(set.mails.count) mails, no project set up, the owner's addresses as in the test guide. The model \(usedModel ? "named the groups" : "was not used, so the groups keep their names in code"), in \(String(format: "%.1f s", time / .seconds(1))) with the grouping.

            Found \(found.count) of \(set.slugs.count) projects: \(found.sorted().joined(separator: ", ")). Not found: \(missing.isEmpty ? "none" : missing.joined(separator: ", ")).

            ## The groups

            Takes is what sorting would file in the project made from the suggestion as prefilled, by the rules alone. Of the label is the project most of those emails carry, with how many of its emails in the set.

            | Suggestion | Description | Anchor | Language | People | Domains | Emails | Takes | Of the label | Share | Others | Found |
            |---|---|---|---|---|---|---|---|---|---|---|---|
            \(lines.joined(separator: "\n"))

            ## Sorting after every suggestion is created

            Every mail sorted again in one batch, oldest first, as the window sorts Needs a Project after a project is created. Other labels counts the emails filed in the project with another label than its most common one.

            | Run | Project | Filed | Sure | Label | Of the label | Other labels |
            |---|---|---|---|---|---|---|
            \(sorted.joined(separator: "\n"))

            """
        return (text, found)
    }

    /// Prints the text, attaches it to the result and writes it to the folder in
    /// TEST_RUNNER_ORRA_PROJECTS_SUGGEST_OUT, when set.
    private static func write(_ text: String, named name: String) throws {
        print(text)
        Attachment.record(text, named: name)
        if let folder = ProcessInfo.processInfo.environment["ORRA_PROJECTS_SUGGEST_OUT"] {
            try text.write(toFile: (folder as NSString).expandingTildeInPath + "/" + name, atomically: true, encoding: .utf8)
        }
    }
}
