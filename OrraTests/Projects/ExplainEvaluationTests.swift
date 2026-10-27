import CryptoKit
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
/// with each mail's words alone, for a run without them from the same build, and a path in
/// it names a retrieval-terms.jsonl of RetrievalEvaluationTests, whose terms it takes without
/// the model, none for a mail the file lacks. The terms job does not count toward the prompt
/// tokens of a row. The runner does not sort, so no mail is set aside.
///
/// Each row lists the prompts of the requests of its explanation, each with its tokens and
/// its SHA-256, never its text, so two builds can be shown to send the same prompts.
/// TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_PROMPTS=only builds the prompts without the model: it
/// loads only the tokenizer, takes the terms from a file or none, and answers every request
/// with nothing, so an explanation has no points and no draft.
///
/// TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_CHOSEN is the path of a JSONL file kept with the set,
/// one line a mail whose answer sits in project files, as
/// `{"id": "m001", "right": ["projects/pic-2026-singapore/invitation-letter.pdf"],
/// "wrong": ["projects/calendar-2027-print/payment-record.txt"]}`, the wrong files of
/// another project and for a few mails only, each path inside the set's folder. The run then
/// explains only the mails the file lists, and each row says for each right and wrong file
/// whether the prompt holds a passage of it, whether a point cites it, and the language of
/// the mail and of the file. TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_CHOOSE=right chooses the right
/// files for each mail, as Choose Files for This Email keeps them, and =wrong chooses the
/// wrong files and explains only the mails that have one. Its rows count the amounts and
/// codes of a draft that only the wrong files hold, and neither the mail, its thread, its
/// project's mail nor the prompt's other excerpts. Without it, the files are measured and
/// not chosen. A failed explanation is then a row with its error, and the run goes on.
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
        let listed = picked.isEmpty ? Array(mails.dropFirst(first - 1).prefix(count)) : mails.filter { picked.contains($0.id) }
        let chosenSetting = environment["ORRA_PROJECTS_EXPLAIN_CHOSEN"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let choose = Choose(rawValue: environment["ORRA_PROJECTS_EXPLAIN_CHOOSE"] ?? "") ?? .none
        try #require(chosenSetting != nil || choose == .none, "TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_CHOOSE needs the files of TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_CHOSEN")
        var labeled: [String: LabeledFiles] = [:]
        if let chosenSetting {
            for line in try String(contentsOf: chosenSetting, encoding: .utf8).split(separator: "\n") where !line.allSatisfy(\.isWhitespace) {
                let files = try JSONDecoder().decode(LabeledFiles.self, from: Data(line.utf8))
                labeled[files.id] = files
            }
        }
        let labels = labeled
        // With labeled files, only the mails they list, and with the wrong files chosen, only
        // those that have one.
        let selected = chosenSetting == nil ? listed : listed.filter { mail in
            labels[mail.id].map { choose != .wrong || !($0.wrong ?? []).isEmpty } ?? false
        }
        try #require(!selected.isEmpty)
        let ownText = environment["ORRA_PROJECTS_EXPLAIN_TEXT"] == "own"
        let termsSetting = environment["ORRA_PROJECTS_EXPLAIN_TERMS"]
        let termsFile = termsSetting.flatMap { $0 == "off" || $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let asksForTerms = termsSetting != "off" && termsFile == nil
        let promptsOnly = environment["ORRA_PROJECTS_EXPLAIN_PROMPTS"] == "only"
        try #require(!promptsOnly || !asksForTerms, "a run of the prompts alone takes its terms from a file or none")
        var termsByID: [String: [String]] = [:]
        if let termsFile {
            for line in try String(contentsOf: termsFile, encoding: .utf8).split(separator: "\n") where !line.allSatisfy(\.isWhitespace) {
                let saved = try JSONDecoder().decode(SavedTerms.self, from: Data(line.utf8))
                termsByID[saved.id] = saved.terms
            }
        }
        let savedTerms = termsByID

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
        let labeledFiles = try await Self.labeledFiles(labels, root: root, database: database)

        // The model, as the app runs it for Projects, unless only the prompts are built.
        let engine = CleanupEngine.live(RewriteEngine(), gate: ModelGate())
        if !promptsOnly {
            try await engine.load(modelFolder)
        }
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
                if termsFile != nil {
                    return byMessageID[email.messageID].flatMap { savedTerms[$0.id] }
                }
                guard asksForTerms else { return nil }
                return try await SearchTerms.ask(for: email, run: { request in try await queue.run(request) }, sleep: { try await Task.sleep(for: $0) })
            },
            chosenFiles: { messageID in
                guard let files = byMessageID[messageID].flatMap({ labels[$0.id] }) else { return [] }
                let paths = switch choose {
                case .none: [String]()
                case .right: files.right
                case .wrong: files.wrong ?? []
                }
                return paths.compactMap { labeledFiles[$0]?.chosen }
            },
            passages: { query, files, perFile in try await search.passages(query, in: files, perFile: perFile) }
        )
        var promptTokens = 0
        // Each request's prompt, by its tokens and its SHA-256.
        var prompts: [Prompt] = []
        let service = ExplainService(
            lookups: lookups,
            run: { request in
                // The explanation's own prompt, not the longer one of a second request
                // for the rest of an answer that repeated itself.
                let tokens = counter.count(request.prompt)
                if promptTokens == 0 {
                    promptTokens = tokens
                }
                prompts.append(Prompt(tokens: tokens, sha256: SHA256.hash(data: Data(request.prompt.utf8)).map { String(format: "%02x", $0) }.joined()))
                return promptsOnly ? "" : try await queue.run(request)
            },
            loadTokenCounter: { counter.count },
            save: { _ in },
            language: language,
            timeZone: Self.timeZone,
            now: { Self.today }
        )

        // Written after each mail, so a run stopped early keeps what it explained.
        let part = picked.isEmpty ? "\(String(format: "%03d", first))-\(String(format: "%03d", first + listed.count - 1))" : "picked"
        let name = "explain-\(language.rawValue)-\(part)" + (ownText ? "-own" : "") + (asksForTerms ? "" : termsFile == nil ? "-noterms" : "-savedterms") + (promptsOnly ? "-prompts" : "")
            + (chosenSetting == nil ? "" : "-chose-\(choose.rawValue)")
        let report = try Self.file(out.appendingPathComponent(name + ".md"))
        let rows = try Self.file(out.appendingPathComponent(name + ".jsonl"))
        defer {
            try? report.close()
            try? rows.close()
        }
        let which = picked.isEmpty && chosenSetting == nil ? "mails \(first) to \(first + selected.count - 1)" : "mails \(selected.map(\.id).joined(separator: ", "))"
        try report.write(contentsOf: Data("# Explanations of the synthetic set\n\nLanguage \(language.rawValue), \(which)\(ownText ? ", each with its own text only" : ""), today 2026-10-18, chip \(SpeechCorpus.chip()). Indexing the 5 project folders took \(Self.seconds(indexTime)).\n".utf8))
        var times: [Duration] = []
        var decisionsRight = 0
        var languagesRight = 0
        var dueReplies = 0
        var failed = 0
        var failure: (any Error)?
        do {
            for mail in selected {
                var email = Self.email(mail, project: mail.labels.project.flatMap { ids[$0] }, ownText: ownText, in: mails, byMessageID: byMessageID)
                email.attachments = await Self.attachments(of: mail, files: projectFiles)
                promptTokens = 0
                prompts = []
                let started = ContinuousClock.now
                let explanation: Explanation
                do {
                    explanation = try await service.explain(email)
                } catch let error where chosenSetting != nil && !(error is CancellationError) {
                    // Counted as a failed explanation, by its kind, never its text.
                    failed += 1
                    let object: [String: Any] = ["id": mail.id, "choose": choose.rawValue, "error": String(reflecting: type(of: error)) + (error is RewriteError ? ".\(error)" : "")]
                    try rows.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data("\n".utf8))
                    continue
                }
                let time = started.duration(to: .now)
                times.append(time)
                let needsReply: Bool = if case .reply = explanation.reply { true } else { false }
                if needsReply == mail.labels.needs_reply { decisionsRight += 1 }
                if mail.labels.needs_reply {
                    dueReplies += 1
                    if explanation.reply.draftLanguage?.rawValue == mail.labels.reply_language { languagesRight += 1 }
                }
                var measures: [String: Any] = [:]
                if let files = labels[mail.id] {
                    measures = Self.measures(files, of: mail, email: email, explanation: explanation, choose: choose, labeledFiles: labeledFiles, mails: mails, byMessageID: byMessageID)
                }
                try report.write(contentsOf: Data(Self.section(mail, explanation, time: time, promptTokens: promptTokens).utf8))
                try rows.write(contentsOf: Data((Self.row(mail, explanation, time: time, promptTokens: promptTokens, prompts: prompts, root: root, measures: measures) + "\n").utf8))
            }
        } catch {
            failure = error
        }
        await engine.unload()
        await database.close()
        if let failure { throw failure }

        // Every explanation may have failed with chosen files, which leaves no time.
        let sorted = times.sorted()
        let median = sorted.isEmpty ? .zero : sorted[sorted.count / 2]
        let p90 = sorted.isEmpty ? .zero : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
        let summary = "\(selected.count) mails: reply decision as labeled for \(decisionsRight), draft language as labeled for \(languagesRight) of \(dueReplies) due replies, \(Self.seconds(median)) a mail at the median and \(Self.seconds(p90)) at p90, \(failed) failed."
        try report.write(contentsOf: Data(("\n## Summary\n\n" + summary + "\n").utf8))
        // Counts only.
        print(summary)
        #expect(times.count + failed == selected.count)
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

    /// A line of a retrieval-terms.jsonl of RetrievalEvaluationTests: a mail's id and its terms.
    private struct SavedTerms: Decodable {
        let id: String
        let terms: [String]?
    }

    /// A prompt a request sent, without its text.
    private struct Prompt {
        let tokens: Int
        let sha256: String
    }

    /// A line of the file of TEST_RUNNER_ORRA_PROJECTS_EXPLAIN_CHOSEN: a mail's id, the files
    /// that answer it and, for a few mails, wrong files of another project, by their paths
    /// inside the set's folder.
    private struct LabeledFiles: Decodable, Sendable {
        let id: String
        let right: [String]
        let wrong: [String]?
    }

    /// Which files a run chooses for each mail: none, the right ones or the wrong ones.
    private enum Choose: String, Sendable {
        case none, right, wrong
    }

    /// A labeled file as the index keeps it: the choice of it, and its text.
    private struct IndexedFile: Sendable {
        let chosen: MailStore.ChosenFile
        let text: String
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

    private static func row(_ mail: SetMail, _ explanation: Explanation, time: Duration, promptTokens: Int, prompts: [Prompt], root: URL, measures: [String: Any]) -> String {
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
        // Each file excerpt the model got, with why it was in the prompt and whether a point
        // cites it.
        let files = explanation.sources
            .compactMap { id, source -> (id: String, chunk: TextChunker.Chunk, origin: ExplainPrompt.FileOrigin?)? in
                guard case .file(let chunk, let origin) = source else { return nil }
                return (id, chunk, origin)
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            .map { file -> [String: Any] in
                [
                    "id": file.id,
                    "name": file.chunk.file.lastPathComponent,
                    "path": Self.inSet(file.chunk.file.path, root: root),
                    "page": file.chunk.page.map { $0 as Any } ?? NSNull(),
                    "reason": file.origin?.reason.map { $0.rawValue as Any } ?? NSNull(),
                    "cited": explanation.points.contains { $0.sources.contains(file.id) },
                ]
            }
        let object: [String: Any] = measures.merging([
            "id": mail.id,
            "attachments_read": explanation.sources.keys.filter { $0.hasPrefix("A") }.count,
            "search_terms": explanation.searchTerms?.count ?? 0,
            "files": files,
            "other_project_files": explanation.sources.keys.filter(ExplainPrompt.isOtherFileSource).sorted(),
            "seconds": time / .seconds(1),
            "prompt_tokens": promptTokens,
            "prompts": prompts.map { ["tokens": $0.tokens, "sha256": $0.sha256] as [String: Any] },
            "reply": describe(explanation.reply),
            "warnings": explanation.warningKinds.map(\.rawValue),
            "model_warnings": explanation.modelWarnings,
            "points": explanation.points.map { ["text": $0.text, "sources": $0.sources, "flags": $0.flags.map { "\($0.kind)" }] },
            "questions": explanation.questions,
            "draft": draft,
            "removals": removals,
            "draft_flags": flags,
            "problems": explanation.problems.map { "\($0)" },
        ], uniquingKeysWith: { _, new in new })
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// A path inside the set's folder, as the labels write it.
    private nonisolated static func inSet(_ path: String, root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// The labeled files as the index keeps them, by their paths in the labels. A path the
    /// index does not hold stops the run, since its mail would measure nothing.
    private static func labeledFiles(_ labels: [String: LabeledFiles], root: URL, database: ProjectsDatabase) async throws -> [String: IndexedFile] {
        let paths = Set(labels.values.flatMap { $0.right + ($0.wrong ?? []) })
        guard !paths.isEmpty else { return [:] }
        let rows = try await database.run(
            "SELECT f.project, f.path, coalesce((SELECT group_concat(c.text, char(10)) FROM index_chunks c WHERE c.file = f.id), '') FROM index_files f",
            []
        )
        var found: [String: IndexedFile] = [:]
        for row in rows {
            guard row.count == 3, let project = row[0].text.flatMap(UUID.init(uuidString:)), let path = row[1].text else { continue }
            let key = inSet(path, root: root)
            if paths.contains(key) {
                found[key] = IndexedFile(chosen: MailStore.ChosenFile(project: project, path: path), text: row[2].text ?? "")
            }
        }
        for path in paths {
            try #require(found[path] != nil, "the index does not hold a labeled file")
        }
        return found
    }

    /// What a row says of a mail's labeled files: for each right and wrong file whether the
    /// prompt holds a passage of it, whether a point cites it, whether it was chosen and its
    /// language, the mail's language, and with the wrong files chosen, the amounts and codes
    /// of the draft only they hold.
    private static func measures(_ files: LabeledFiles, of mail: SetMail, email: ExplainService.Email, explanation: Explanation, choose: Choose, labeledFiles: [String: IndexedFile], mails: [SetMail], byMessageID: [String: SetMail]) -> [String: Any] {
        let excerpts = explanation.sources.compactMap { id, source -> (id: String, chunk: TextChunker.Chunk, origin: ExplainPrompt.FileOrigin?)? in
            guard case .file(let chunk, let origin) = source else { return nil }
            return (id, chunk, origin)
        }
        func measure(_ path: String) -> [String: Any] {
            let indexed = labeledFiles[path]
            let own = excerpts.filter { $0.chunk.file.path == indexed?.chosen.path }
            let text = indexed?.text ?? ""
            return [
                "path": path,
                "language": language(of: text),
                "with_text": !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "in_prompt": own.contains { !$0.chunk.text.isEmpty },
                "cited": explanation.points.contains { point in own.contains { point.sources.contains($0.id) } },
                "chosen": own.contains { $0.origin?.reason == .chosen },
            ]
        }
        var measures: [String: Any] = [
            "choose": choose.rawValue,
            "mail_language": language(of: email.text),
            "labeled": files.right.map(measure),
        ]
        if let wrong = files.wrong, !wrong.isEmpty {
            measures["wrong"] = wrong.map(measure)
            if choose == .wrong, case .checked(let result) = explanation.draft, let draft = result.draft {
                let wrongPaths = Set(wrong.compactMap { labeledFiles[$0]?.chosen.path })
                let others = excerpts.filter { !wrongPaths.contains($0.chunk.file.path) }.map(\.chunk.text)
                let attachments = explanation.sources.values.compactMap { source -> String? in
                    guard case .attachment(_, let excerpt) = source else { return nil }
                    return excerpt
                }
                let thread = thread(of: mail, in: mails, byMessageID: byMessageID).map(\.body)
                let projectMail = mails.filter { $0.labels.project == mail.labels.project }.map(\.body)
                let known = ([email.subject, email.text, email.visibleText] + thread + projectMail + others + attachments).joined(separator: "\n\n")
                measures["wrong_values_in_draft"] = wrongValues(in: draft, wrong: wrong.compactMap { labeledFiles[$0]?.text }.joined(separator: "\n\n"), known: known)
            }
        }
        return measures
    }

    /// zh when at least a tenth of a text's characters are Chinese, else en, as the set's
    /// mails and files are in one of the two.
    private nonisolated static func language(of text: String) -> String {
        let han = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return han * 10 >= max(1, text.count) ? "zh" : "en"
    }

    /// How many amounts and codes of a draft only the wrong files hold: the amounts and codes
    /// of their text that the known texts do not hold, as the draft check compares values.
    nonisolated static func wrongValues(in draft: String, wrong: String, known: String) -> Int {
        let wrong = wrong.precomposedStringWithCompatibilityMapping
        let known = known.precomposedStringWithCompatibilityMapping
        let draft = draft.precomposedStringWithCompatibilityMapping
        let knownValues = Set(OutputChecks.numbers(in: known, skippingDatesAndCodes: false).map(\.value))
        let amounts = Set(OutputChecks.numbers(in: wrong).filter(\.isAmount).map(\.value)).subtracting(knownValues)
        let knownCodes = Set(OutputChecks.codes(in: known).map { OutputChecks.codeValue(known[$0]) })
        let codes = Set(OutputChecks.codes(in: wrong).map { OutputChecks.codeValue(wrong[$0]) }).subtracting(knownCodes)
        return OutputChecks.numbers(in: draft).count { amounts.contains($0.value) }
            + OutputChecks.codes(in: draft).count { codes.contains(OutputChecks.codeValue(draft[$0])) }
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
