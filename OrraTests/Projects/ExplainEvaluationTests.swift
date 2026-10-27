import Foundation
import Testing
@testable import Orra

/// Explains the mails of the synthetic Projects set with the real cleanup model, and writes
/// the explanations for reading. Only when asked for, with TEST_RUNNER_ORRA_PROJECTS_EXPLAIN
/// set to the set's folder, the set owner's addresses and name from the set's README, and
/// TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_OUT set to a folder for the results. Never in CI, and
/// in a Release build, since a Debug build runs MLX without optimization:
///
///     TEST_RUNNER_ORRA_PROJECTS_EXPLAIN=~/projects/orra-project/bench/projects-testset \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES=<work address>,<home address> \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_NAME=<name> \
///     TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_OUT=<folder> \
///     xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test -only-testing:OrraTests/ExplainEvaluationTests
///
/// TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_FIRST and TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_COUNT pick a
/// part of the 105 mails, by their place in mail.jsonl from 1, so a long evaluation runs in
/// parts. TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_IDS picks mails by their ids in the set instead,
/// comma separated. TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_LANGUAGE is zh (the default) or en, the
/// language of the explanations. TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_TEXT=own gives every mail
/// its own text as the store keeps it, without its quoted history, as the app does.
///
/// Otherwise it runs the mails as phase 0 did, with today pinned to 2026-10-18, the day the
/// labels hold for: each mail in its labeled project, with that project's files indexed by
/// FolderIndex and found by ChunkSearch, its thread from the set's thread ids and Message-ID
/// links, the project's other mail ranked by the words it shares with the mail, and the set
/// owner as the user. The model runs through ProjectsModelQueue, as a request of the user. The set
/// stays outside the repository, and so do the results, which hold its text.
///
/// The set lists attachments by name and type. An attachment named as a file in the set's
/// project folders comes with that file, as when a supplier mails the quote that is also in
/// the folder, and MailAttachment reads it as it reads an attachment in Mail. The others are
/// names and types. TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_ATTACHMENTS=names reads them all as
/// names and types, as Orra did before it read attachments, for a baseline from the same
/// build.
///
/// It searches with search terms from the model and with other projects' files where the
/// app reads them, see ExplainService. TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_TERMS=off searches
/// with each mail's words alone, for a run without them from the same build. The terms job does not count toward the prompt tokens of a row. The runner
/// does not sort, so no mail is set aside.
@Suite(.serialized, .enabled(if: ExplainEvaluationSet.folder != nil && !ExplainEvaluationSet.ownAddresses.isEmpty && RewriteTestModel.folder != nil))
@MainActor
struct ExplainEvaluationTests {
    private nonisolated static let today = ISO8601DateFormatter().date(from: "2026-10-18T20:00:00+08:00")!
    private nonisolated static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    private nonisolated static let ownName = ExplainEvaluationSet.ownName
    private nonisolated static let ownAddresses = ExplainEvaluationSet.ownAddresses

    @Test func explainTheSet() async throws {
        let root = try #require(ExplainEvaluationSet.folder)
        let modelFolder = try #require(RewriteTestModel.folder)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: ((environment["ORRA_PROJECTS_EXPLAIN_OUT"] ?? NSTemporaryDirectory()) as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let language: ProjectsLanguage = environment["ORRA_PROJECTS_EXPLAIN_LANGUAGE"] == "en" ? .en : .zh
        let readsAttachments = environment["ORRA_PROJECTS_EXPLAIN_ATTACHMENTS"] != "names"

        let mails = try String(contentsOf: root.appendingPathComponent("mail.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(SetMail.self, from: Data($0.utf8)) }
        let setProjects = try JSONDecoder().decode([SetProject].self, from: Data(contentsOf: root.appendingPathComponent("projects/projects.json")))
        let first = max(1, Int(environment["ORRA_PROJECTS_EXPLAIN_FIRST"] ?? "") ?? 1)
        let count = Int(environment["ORRA_PROJECTS_EXPLAIN_COUNT"] ?? "") ?? mails.count
        let picked = Set((environment["ORRA_PROJECTS_EXPLAIN_IDS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let chosen = picked.isEmpty ? Array(mails.dropFirst(first - 1).prefix(count)) : mails.filter { picked.contains($0.id) }
        try #require(!chosen.isEmpty)
        let ownText = environment["ORRA_PROJECTS_EXPLAIN_TEXT"] == "own"
        let asksForTerms = environment["ORRA_PROJECTS_EXPLAIN_TERMS"] != "off"

        // The projects, with their files indexed in a folder of their own.
        let ids = Dictionary(uniqueKeysWithValues: setProjects.enumerated().map { index, project in
            (project.slug, UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!)
        })
        let projects = setProjects.map { project in
            ExplainService.Project(
                id: ids[project.slug]!,
                name: project.name,
                description: project.description,
                people: project.people.map(Self.person),
                domains: project.domains
            )
        }
        // The index holds the set's text, so it goes whichever way the run ends.
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ExplainEvaluationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let storage = ProjectsStorage(root: storageRoot)
        let database = try await ProjectsDatabase.open(in: storage)
        let index = FolderIndex(database: database, isDictating: { false }, watch: { _, _, _ in {} })
        let indexStarted = ContinuousClock.now
        for project in setProjects {
            index.start(project: ids[project.slug]!, folders: [root.appendingPathComponent(project.folder, isDirectory: true)])
        }
        await index.waitUntilIdle()
        let indexTime = indexStarted.duration(to: .now)
        index.stopAll()
        let search = ChunkSearch(database: database)

        // The model, as the app runs it for Projects.
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

        let byMessageID = Dictionary(mails.map { (Self.bare($0.message_id), $0) }, uniquingKeysWith: { first, _ in first })
        // The files of the project folders by name, for the attachments named as one.
        var projectFiles: [String: URL] = [:]
        if readsAttachments {
            for project in setProjects {
                let folder = root.appendingPathComponent(project.folder, isDirectory: true)
                for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where projectFiles[name] == nil {
                    projectFiles[name] = folder.appendingPathComponent(name)
                }
            }
        }
        let lookups = ExplainService.Lookups(
            // Only mail dated before this one counts, since a later mail cannot make its
            // sender known or hold a quote of the user.
            known: { email in
                let earlier = mails.filter { Self.date($0.date) < email.date }
                var correspondents: [SenderChecks.Person] = []
                var seen: Set<String> = []
                for mail in earlier {
                    for value in [mail.from] + mail.to + (mail.cc ?? []) {
                        let person = Self.person(value)
                        guard let address = ProjectsAddress.normalized(person.address), !Self.ownAddresses.contains(address), seen.insert(address).inserted else { continue }
                        correspondents.append(SenderChecks.Person(name: person.name, address: address))
                    }
                }
                let sent = earlier.filter { Self.isOwn($0.from) }.map(\.body)
                return ExplainService.Known(ownName: Self.ownName, ownAddresses: Self.ownAddresses, projects: projects, correspondents: correspondents, sentTexts: sent)
            },
            thread: { email in
                guard let mail = byMessageID[email.messageID] else { return [] }
                return Self.thread(of: mail, in: mails, byMessageID: byMessageID).map(Self.promptMail)
            },
            projectMail: { query in
                let slug = ids.first { $0.value == query.project }?.key
                let words = Set(ChunkSearch.words(in: query.text).filter { $0.count > 1 })
                let ranked = mails
                    .filter { $0.labels.project == slug && !query.excluding.contains(Self.bare($0.message_id)) }
                    .map { mail in (mail, words.intersection(ChunkSearch.words(in: mail.subject + "\n" + mail.body)).count) }
                    .filter { $0.1 > 0 }
                    .sorted { $0.1 > $1.1 }
                return ranked.prefix(query.limit).map { Self.promptMail($0.0) }
            },
            search: { query in try await search.search(query) },
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
            terms: { email in
                guard asksForTerms else { return nil }
                return try await SearchTerms.ask(for: email, run: { request in try await queue.run(request) }, sleep: { try await Task.sleep(for: $0) })
            }
        )
        var promptTokens = 0
        let service = ExplainService(
            lookups: lookups,
            run: { request in
                // The explanation's own prompt, not the longer one of a second request
                // for the rest of an answer that repeated itself.
                if promptTokens == 0 {
                    promptTokens = counter.count(request.prompt)
                }
                return try await queue.run(request)
            },
            loadTokenCounter: { counter.count },
            save: { _ in },
            language: language,
            timeZone: Self.timeZone,
            now: { Self.today }
        )

        // Written after each mail, so a run stopped early keeps what it explained.
        let part = picked.isEmpty ? "\(String(format: "%03d", first))-\(String(format: "%03d", first + chosen.count - 1))" : "picked"
        let name = "explain-\(language.rawValue)-\(part)" + (ownText ? "-own" : "") + (asksForTerms ? "" : "-noterms")
        let report = try Self.file(out.appendingPathComponent(name + ".md"))
        let rows = try Self.file(out.appendingPathComponent(name + ".jsonl"))
        defer {
            try? report.close()
            try? rows.close()
        }
        let which = picked.isEmpty ? "mails \(first) to \(first + chosen.count - 1)" : "mails \(chosen.map(\.id).joined(separator: ", "))"
        try report.write(contentsOf: Data("# Explanations of the synthetic set\n\nLanguage \(language.rawValue), \(which)\(ownText ? ", each with its own text only" : ""), today 2026-10-18, chip \(SpeechCorpus.chip()). Indexing the 5 project folders took \(Self.seconds(indexTime)).\n".utf8))
        var times: [Duration] = []
        var decisionsRight = 0
        var languagesRight = 0
        var dueReplies = 0
        var failure: (any Error)?
        do {
            for mail in chosen {
                var email = Self.email(mail, project: mail.labels.project.flatMap { ids[$0] }, ownText: ownText, in: mails, byMessageID: byMessageID)
                email.attachments = await Self.attachments(of: mail, files: projectFiles)
                promptTokens = 0
                let started = ContinuousClock.now
                let explanation = try await service.explain(email)
                let time = started.duration(to: .now)
                times.append(time)
                let needsReply: Bool = if case .reply = explanation.reply { true } else { false }
                if needsReply == mail.labels.needs_reply { decisionsRight += 1 }
                if mail.labels.needs_reply {
                    dueReplies += 1
                    if explanation.reply.draftLanguage?.rawValue == mail.labels.reply_language { languagesRight += 1 }
                }
                try report.write(contentsOf: Data(Self.section(mail, explanation, time: time, promptTokens: promptTokens).utf8))
                try rows.write(contentsOf: Data((Self.row(mail, explanation, time: time, promptTokens: promptTokens) + "\n").utf8))
            }
        } catch {
            failure = error
        }
        await engine.unload()
        await database.close()
        if let failure { throw failure }

        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
        let summary = "\(chosen.count) mails: reply decision as labeled for \(decisionsRight), draft language as labeled for \(languagesRight) of \(dueReplies) due replies, \(Self.seconds(median)) a mail at the median and \(Self.seconds(p90)) at p90."
        try report.write(contentsOf: Data(("\n## Summary\n\n" + summary + "\n").utf8))
        // Counts only.
        print(summary)
        #expect(times.count == chosen.count)
    }

    // MARK: The set

    private struct SetMail: Decodable {
        struct Attachment: Decodable {
            let name: String
            let type: String
        }

        struct Labels: Decodable {
            let project: String?
            let needs_reply: Bool
            let reply_language: String?
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
        ProjectsAddress.normalized(person(value).address).map(ownAddresses.contains) ?? false
    }

    /// The other mails of the thread: those with its thread id, and those its In-Reply-To
    /// and References name, in date order.
    private nonisolated static func thread(of mail: SetMail, in mails: [SetMail], byMessageID: [String: SetMail]) -> [SetMail] {
        var found: [String: SetMail] = [:]
        if let thread = mail.thread {
            for other in mails where other.thread == thread && other.id != mail.id {
                found[other.id] = other
            }
        }
        for id in [mail.in_reply_to].compactMap({ $0 }) + (mail.references ?? []) {
            if let other = byMessageID[bare(id)], other.id != mail.id {
                found[other.id] = other
            }
        }
        return found.values.sorted { date($0.date) < date($1.date) }
    }

    private nonisolated static func promptMail(_ mail: SetMail) -> ExplainPrompt.Mail {
        ExplainPrompt.Mail(
            messageID: bare(mail.message_id),
            date: date(mail.date),
            sender: person(mail.from),
            to: mail.to.map(person),
            cc: (mail.cc ?? []).map(person),
            subject: mail.subject,
            attachmentNames: (mail.attachments ?? []).map(\.name),
            text: QuotedHistory(splitting: mail.body, subject: mail.subject).ownText
        )
    }

    /// The email as projects-mail-text gives it: its own text without the quoted history
    /// when the message it answers is in its thread, as in phase 0, or always with
    /// `ownText`, as the store keeps it for the app.
    private nonisolated static func email(_ mail: SetMail, project: UUID?, ownText: Bool, in mails: [SetMail], byMessageID: [String: SetMail]) -> ExplainService.Email {
        let parentKnown = mail.in_reply_to.map { byMessageID[bare($0)] != nil } ?? false
        let split = QuotedHistory(splitting: mail.body, subject: mail.subject)
        let text = ownText || (parentKnown && !split.quotedText.isEmpty) ? split.ownText : mail.body
        return ExplainService.Email(
            messageID: bare(mail.message_id),
            date: date(mail.date),
            sender: person(mail.from),
            to: mail.to.map(person),
            cc: (mail.cc ?? []).map(person),
            subject: mail.subject,
            attachments: (mail.attachments ?? []).map { MailAttachment(name: $0.name, type: $0.type, state: .otherType) },
            text: text,
            visibleText: mail.body,
            project: project
        )
    }

    // MARK: The results

    private static func section(_ mail: SetMail, _ explanation: Explanation, time: Duration, promptTokens: Int) -> String {
        var text = "\n## \(mail.id): \(mail.subject)\n\n"
        text += "From \(mail.from), \(mail.date). Labeled project \(mail.labels.project ?? "none"), needs a reply: \(mail.labels.needs_reply ? "yes, in \(mail.labels.reply_language ?? "?")" : "no"). \(promptTokens) prompt tokens, \(seconds(time)).\n\n"
        text += "Reply rule: \(describe(explanation.reply)). Warnings found in code: \(nonEmpty(explanation.warnings.map { "\($0.warning.rawValue) (\(place($0.place)))" }.joined(separator: ", "), or: "none")).\n"
        if !explanation.problems.isEmpty {
            text += "Problems of form: \(explanation.problems.map { "\($0)" }.joined(separator: ", ")).\n"
        }
        text += "\n**Warnings**\n\n" + list(explanation.modelWarnings)
        text += "\n**Points**\n\n" + list(explanation.points.map { point in
            point.text + (point.sources.isEmpty ? "" : " [" + point.sources.joined(separator: ", ") + "]")
                + (point.flags.isEmpty ? "" : " (flagged: " + point.flags.map { "\($0.kind) \($0.text)" }.joined(separator: ", ") + ")")
        })
        text += "\n**Before you reply**\n\n" + list(explanation.questions)
        text += "\n**Draft**\n\n"
        switch explanation.draft {
        case .checked(let result):
            if let draft = result.draft {
                text += "```\n" + draft + "\n```\n"
            } else {
                text += "Held back: it reads as \(result.language.rawValue).\n"
            }
            if !result.removals.isEmpty {
                text += "\nRemoved: " + result.removals.map { "\($0.kind.rawValue) “\($0.text)”" }.joined(separator: ", ") + "\n"
            }
            if !result.flags.isEmpty {
                text += "\nFlags: " + result.flags.map { "\($0)" }.joined(separator: ", ") + "\n"
            }
        case .noReply(let reason):
            text += "No reply due (\(reason.rawValue)).\n"
        case .noDraft:
            text += "No draft for this language.\n"
        case .missing:
            text += "Missing: the model wrote no draft.\n"
        case .expired:
            text += "Expired: Retention removed the draft.\n"
        }
        return text
    }

    private static func row(_ mail: SetMail, _ explanation: Explanation, time: Duration, promptTokens: Int) -> String {
        var draft: Any = NSNull()
        var removals: [String] = []
        var flags: [String] = []
        switch explanation.draft {
        case .checked(let result):
            draft = result.draft ?? NSNull()
            removals = result.removals.map(\.kind.rawValue)
            flags = result.flags.map { "\($0)" }
        case .noReply(let reason):
            draft = "no reply: \(reason.rawValue)"
        case .noDraft:
            draft = "no draft"
        case .missing:
            draft = "missing"
        case .expired:
            draft = "expired"
        }
        let object: [String: Any] = [
            "id": mail.id,
            "attachments_read": explanation.sources.keys.filter { $0.hasPrefix("A") }.count,
            "search_terms": explanation.searchTerms?.count ?? 0,
            "files": explanation.sources.keys.filter { $0.hasPrefix("F") }.sorted(),
            "other_project_files": explanation.sources.keys.filter(ExplainPrompt.isOtherFileSource).sorted(),
            "seconds": time / .seconds(1),
            "prompt_tokens": promptTokens,
            "reply": describe(explanation.reply),
            "warnings": explanation.warningKinds.map(\.rawValue),
            "model_warnings": explanation.modelWarnings,
            "points": explanation.points.map { ["text": $0.text, "sources": $0.sources, "flags": $0.flags.map { "\($0.kind)" }] },
            "questions": explanation.questions,
            "draft": draft,
            "removals": removals,
            "draft_flags": flags,
            "problems": explanation.problems.map { "\($0)" },
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ decision: ReplyRule.Decision) -> String {
        switch decision {
        case .noReply(let reason): "no reply (\(reason.rawValue))"
        case .reply(let language): "reply in \(language.rawValue)"
        }
    }

    private static func place(_ place: ExplainPrompt.Place) -> String {
        switch place {
        case .email: "email"
        case .file(let id), .thread(let id), .projectMail(let id), .attachment(let id): id
        }
    }

    /// The mail's attachments as MailAttachment reads them from the parts of its source, as
    /// the scan does: with the file of the project folders that has the attachment's name,
    /// else as an empty part, which keeps its name and type only.
    private nonisolated static func attachments(of mail: SetMail, files: [String: URL]) async -> [MailAttachment] {
        let attached = (mail.attachments ?? []).map { attachment in
            let data = files[attachment.name].flatMap { try? Data(contentsOf: $0) }
            return AttachedFiles.File(name: attachment.name, type: attachment.type, data: data ?? Data())
        }
        return await MailAttachment.read(AttachedFiles.parts(attached), modified: date(mail.date))
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "- none\n" : items.map { "- " + $0 }.joined(separator: "\n") + "\n"
    }

    /// A new empty file to write to.
    private static func file(_ url: URL) throws -> FileHandle {
        try Data().write(to: url)
        return try FileHandle(forWritingTo: url)
    }

    private static func nonEmpty(_ text: String, or replacement: String) -> String {
        text.isEmpty ? replacement : text
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", duration / .seconds(1))
    }
}

/// The synthetic set and its owner, from the environment, so neither is in the repository.
nonisolated private enum ExplainEvaluationSet {
    /// The set's folder in TEST_RUNNER_ORRA_PROJECTS_EXPLAIN, when it holds the mail.
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORRA_PROJECTS_EXPLAIN"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("mail.jsonl").path) ? url : nil
    }

    /// The owner's addresses in TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES, comma separated and
    /// normalized.
    static let ownAddresses: [String] = (ProcessInfo.processInfo.environment["ORRA_PROJECTS_OWN_ADDRESSES"] ?? "")
        .split(separator: ",")
        .compactMap { ProjectsAddress.normalized(String($0)) }

    /// The owner's name in TEST_RUNNER_ORRA_PROJECTS_OWN_NAME.
    static let ownName = ProcessInfo.processInfo.environment["ORRA_PROJECTS_OWN_NAME"] ?? ""
}
