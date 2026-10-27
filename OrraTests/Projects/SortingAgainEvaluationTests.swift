import Foundation
import Synchronization
import Testing
@testable import Orra

/// Sorts the 105 mails of the synthetic set of phase 0 as the app does while the projects
/// change: through ProjectsRuntime with the Projects window open, the real cleanup model,
/// the real index of the project folders, and a stand in for Mail with one mailbox that
/// holds orra-test.mbox, which Tools/release-gate/projects_mbox.py makes from the set. It
/// never sends an Apple Event. Only when asked for, never in CI, in a Release build, since
/// a Debug build runs MLX without optimization:
///
///     TEST_RUNNER_ORRA_PROJECTS_SET=~/projects/orra-project/bench/projects-testset \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES=<work address>,<home address> \
///     TEST_RUNNER_ORRA_PROJECTS_OWN_NAME=<name> \
///     TEST_RUNNER_ORRA_PROJECTS_RESORT_OUT=<folder> \
///     xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/SortingAgainEvaluationTests
///
/// The user's addresses and name are those of the set's owner, from its README, as the
/// Debug override of the test guide gives them. Each test has a store of its own, and today
/// is pinned to 2026-10-25, the day of round two of the test guide.
/// - `projectsMadeOneAtATime()` follows round two. Projects reads the mail with no project.
///   Then it makes each project from Suggested Projects as the window offers it once
///   sorting finished, saved unchanged as New Project is prefilled: the first suggestion
///   whose emails mostly carry the label of a project not made yet. Then it edits each
///   project, in the order they were made, to the name, description, people, domains and
///   folder of projects.json. Sorting finishes after each change.
/// - `projectsBeforeTheMail()` makes the five projects of projects.json first, waits for
///   their index, and reads the mail only then.
///
/// TEST_RUNNER_ORRA_PROJECTS_RESORT_ORDER, slugs separated by commas, makes the projects in
/// that order instead, each from the first suggestion whose emails mostly carry its label,
/// or with `<slug>=<anchor>` from the suggestion of that domain, address or word.
/// TEST_RUNNER_ORRA_PROJECTS_RESORT_DISMISS, the domains, addresses or words of suggestions
/// separated by commas, dismisses those before the first project is made, as a user may.
/// A project that no suggestion offers is made by hand from projects.json, without its
/// folder until the edits.
///
/// A mail is right in the project of its label, or outside every project when its label is
/// none. A mail of a project that sits in Needs a Project waits, and anything else is
/// wrong. The bar of the test guide is at most 6 wrong of 105. Each test writes one JSON
/// file into the folder again after each step, so a run cut short keeps what it did: the
/// counts after each step, the model's jobs and the time, and every mail by its id with its
/// label, where it is, its level and its reasons. Never mail text, names or addresses. The
/// test prints counts only.
@Suite(.serialized, .enabled(if: ["ORRA_PROJECTS_SET", "ORRA_PROJECTS_OWN_ADDRESSES", "ORRA_PROJECTS_OWN_NAME", "ORRA_PROJECTS_RESORT_OUT"].allSatisfy { ProcessInfo.processInfo.environment[$0] != nil } && RewriteTestModel.folder != nil))
@MainActor
struct SortingAgainEvaluationTests {
    /// The afternoon of round two of the test guide, Pacific time.
    nonisolated static let today = ISO8601DateFormatter().date(from: "2026-10-25T16:00:00-07:00")!
    /// The most mails in a wrong project, as step 3.4 of the test guide allows.
    nonisolated static let bar = 6
    /// The longest sorting may take to finish after one change, a bound and not a measure.
    nonisolated static let settleLimit: Duration = .seconds(90 * 60)

    @Test(.timeLimit(.minutes(300)))
    func projectsMadeOneAtATime() async throws {
        let setup = try Setup()
        let run = try await Run(setup, name: "one-at-a-time")
        let result: Run.Result
        do {
            try await run.readMail()
            try await run.record("read the mail with no project")
            let suggestions = run.runtime.suggestionService()
            try await run.dismiss(in: suggestions)
            for position in setup.set.projects.indices {
                try await run.makeFromSuggestion(suggestions, wanted: setup.order.indices.contains(position) ? setup.order[position] : nil)
            }
            for project in run.runtime.projectList {
                try await run.edit(project.id, suggestions)
            }
            result = try await run.finish()
        } catch {
            await run.stop()
            throw error
        }
        await run.stop()
        #expect(result.missing == 0, "\(result.missing) mails not in the store")
        #expect(result.wrong <= Self.bar, "\(result.wrong) wrong")
    }

    @Test(.timeLimit(.minutes(120)))
    func projectsBeforeTheMail() async throws {
        let setup = try Setup()
        let run = try await Run(setup, name: "projects-first")
        let result: Run.Result
        do {
            for project in setup.set.projects {
                try await run.makeByHand(project, withFolder: true)
            }
            try await run.settle()
            try await run.record("made the five projects of projects.json")
            try await run.readMail()
            try await run.record("read the mail")
            result = try await run.finish()
        } catch {
            await run.stop()
            throw error
        }
        await run.stop()
        #expect(result.missing == 0, "\(result.missing) mails not in the store")
        #expect(result.wrong <= Self.bar, "\(result.wrong) wrong")
    }

    // MARK: The setup

    /// What both tests read: the set, the stand in for Mail, the user and the options.
    struct Setup {
        let root: URL
        let set: SetLabels
        let mail: SetMailbox
        let owner: SortingService.Owner
        let model: URL
        let out: URL
        /// The projects in the order to make them, empty for the order of the suggestions.
        let order: [Wanted]
        /// The anchors of the suggestions to dismiss, lowercased.
        let dismissals: Set<String>

        init() throws {
            let environment = ProcessInfo.processInfo.environment
            func folder(_ name: String) throws -> URL {
                let path = try #require(environment[name], "TEST_RUNNER_\(name) is not set")
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
            func list(_ name: String) -> [String] {
                (environment[name] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            root = try folder("ORRA_PROJECTS_SET")
            out = try folder("ORRA_PROJECTS_RESORT_OUT")
            model = try #require(RewriteTestModel.folder)
            set = try SetLabels(root: root)
            try #require(set.ids.count == 105 && set.projects.count == 5, "the set holds \(set.ids.count) mails and \(set.projects.count) projects")
            let mbox = root.appendingPathComponent("orra-test.mbox")
            try #require(FileManager.default.fileExists(atPath: mbox.path), "orra-test.mbox is missing, see Tools/release-gate/projects_mbox.py")
            mail = try SetMailbox(mbox: mbox)
            try #require(mail.messages.count == set.ids.count, "orra-test.mbox holds \(mail.messages.count) messages")
            let addresses = list("ORRA_PROJECTS_OWN_ADDRESSES").compactMap(ProjectsAddress.normalized)
            try #require(!addresses.isEmpty, "TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES holds no address")
            owner = SortingService.Owner(addresses: addresses, name: environment["ORRA_PROJECTS_OWN_NAME"])
            order = list("ORRA_PROJECTS_RESORT_ORDER").map { item in
                let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return Wanted(slug: parts[0], anchor: parts.count > 1 ? parts[1].lowercased() : nil)
            }
            let slugs = Set(set.projects.map(\.slug))
            try #require(order.allSatisfy { slugs.contains($0.slug) } && Set(order.map(\.slug)).count == order.count, "TEST_RUNNER_ORRA_PROJECTS_RESORT_ORDER names a slug twice or one the set does not have")
            dismissals = Set(list("ORRA_PROJECTS_RESORT_DISMISS").map { $0.lowercased() })
        }
    }

    /// A project to make from a suggestion: its slug, and the domain, address or word that
    /// holds the suggestion together, lowercased, or nil for the first suggestion whose
    /// emails mostly carry the label of the slug.
    nonisolated struct Wanted: Sendable {
        var slug: String
        var anchor: String?
    }

    /// The projects and the labels of the synthetic set, from projects.json and mail.jsonl.
    nonisolated struct SetLabels: Sendable {
        nonisolated struct SetProject: Decodable, Sendable {
            let slug: String
            let name: String
            let description: String
            let folder: String
            /// As "Name <address>".
            let people: [String]
            let domains: [String]
        }

        private nonisolated struct SetMail: Decodable, Sendable {
            nonisolated struct Labels: Decodable, Sendable {
                let project: String?
            }

            let id: String
            let message_id: String
            let labels: Labels
        }

        let projects: [SetProject]
        /// The set's ids, in date order.
        let ids: [String]
        /// The slug of each id's project, or none.
        let labels: [String: String]
        /// The set's id of each Message-ID, without angle brackets.
        private let byMessageID: [String: String]

        init(root: URL) throws {
            let decoder = JSONDecoder()
            projects = try decoder.decode([SetProject].self, from: Data(contentsOf: root.appendingPathComponent("projects/projects.json")))
            let mails = try String(contentsOf: root.appendingPathComponent("mail.jsonl"), encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.allSatisfy(\.isWhitespace) }
                .map { try decoder.decode(SetMail.self, from: Data($0.utf8)) }
            ids = mails.map(\.id)
            labels = Dictionary(mails.map { ($0.id, $0.labels.project ?? "none") }, uniquingKeysWith: { first, _ in first })
            byMessageID = Dictionary(mails.map { ($0.message_id.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")), $0.id) }, uniquingKeysWith: { first, _ in first })
        }

        /// The set's id of a Message-ID, or the Message-ID when the set has none.
        func id(of messageID: String) -> String {
            byMessageID[messageID] ?? messageID
        }

        /// The folder of a project in the set, whose path projects.json gives from the set's
        /// folder.
        func folder(of project: SetProject, in root: URL) -> URL {
            root.appendingPathComponent(project.folder, isDirectory: true)
        }
    }

    // MARK: Outcomes

    /// Where an email of the set is, as a test reads it from the store.
    nonisolated struct Placement: Sendable {
        /// The project's slug, needsProject or setAside.
        var place: String
        var level: String
        var reasons: [String]
        var movedByUser: Bool
    }

    nonisolated enum Outcome: String, Sendable {
        case right, wrong, waiting
    }

    /// Right in the project of the label, or outside every project for a label of none. A
    /// mail of a project in Needs a Project waits.
    nonisolated static func outcome(label: String, place: String) -> Outcome {
        if label == "none" {
            return place == "needsProject" || place == "setAside" ? .right : .wrong
        }
        if place == label {
            return .right
        }
        return place == "needsProject" ? .waiting : .wrong
    }

    // MARK: A run

    /// One run of Projects with a store, preferences and a model of its own, and what it
    /// measured.
    @MainActor final class Run {
        struct Result {
            var right: Int
            var wrong: Int
            var waiting: Int
            var missing: Int
        }

        let setup: Setup
        let name: String
        let projects: ProjectsSwitch
        let choice: MailChoice
        let runtime: ProjectsRuntime
        let jobs: ModelJobs
        private let engine: CleanupEngine
        private let folder: URL
        private let suite: String
        private let defaults: UserDefaults
        /// The slug of each project made, by its ID.
        private var slugs: [UUID: String] = [:]
        /// The slugs in the order the projects were made, with how each was made.
        private var made: [[String: Any]] = []
        private var steps: [[String: Any]] = []
        private let started = ContinuousClock.now
        private var stepStarted = ContinuousClock.now
        private var jobsBefore = ModelJobs.Counts()

        init(_ setup: Setup, name: String) async throws {
            self.setup = setup
            self.name = name
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SortingAgainEvaluation-\(UUID().uuidString)", isDirectory: true)
            self.folder = folder
            let suite = "io.github.db-ol.OrraTests.sorting-again-\(UUID().uuidString)"
            self.suite = suite
            let defaults = try #require(UserDefaults(suiteName: suite))
            self.defaults = defaults
            let storage = ProjectsStorage(root: folder.appendingPathComponent("Support", isDirectory: true))
            let projects = ProjectsSwitch(defaults: defaults, isVisible: true, physicalMemory: 32 << 30, storage: storage)
            projects.turnOn()
            self.projects = projects
            // The imported mailbox alone, back far enough for the oldest mail of the set.
            let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
            choice.choose([SetMailbox.mailbox])
            choice.choose(days: 180)
            self.choice = choice
            let engine = CleanupEngine.live(RewriteEngine(), gate: ModelGate())
            try await engine.load(setup.model)
            self.engine = engine
            let jobs = ModelJobs()
            self.jobs = jobs
            let environment = jobs.environment(engine)
            let bridge = setup.mail.bridge
            let owner = setup.owner
            runtime = ProjectsRuntime(projects: projects, dependencies: ProjectsRuntime.Dependencies(
                storage: storage,
                bridge: bridge,
                choice: choice,
                ownerOverride: { owner },
                language: .zh,
                isDictating: { false },
                modelEnvironment: { _ in environment },
                modelIsInstalled: { true },
                loadTokenCounter: { nil },
                handoff: ReplyHandoff(copy: { _ in true }, mail: bridge, isOrraActive: { true }, bringMailToFront: {}),
                watchesMemoryPressure: false,
                watchFolders: { _, _, _ in {} },
                now: { SortingAgainEvaluationTests.today },
                // One pass of the scan, and no sweep of the index but the ones a change starts.
                sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
            ))
            runtime.follow()
            let starting = ContinuousClock.now
            while runtime.phase != .on {
                try #require(runtime.phase != .failed && starting.duration(to: .now) < .seconds(60), "Projects did not start")
                try await Task.sleep(for: .milliseconds(10))
            }
            runtime.windowOpened()
        }

        /// Confirms the mailbox choice, so the scan reads the mail, and waits until the store
        /// holds all of it and sorting finished.
        func readMail() async throws {
            choice.confirm()
            let reading = ContinuousClock.now
            while (await runtime.counts()?.emails ?? 0) < setup.mail.messages.count {
                try #require(reading.duration(to: .now) < .seconds(600), "the scan did not save the mail")
                try await Task.sleep(for: .milliseconds(100))
            }
            try await settle()
        }

        /// Waits until sorting, the index and the naming of suggestions have nothing left to
        /// do, for a few looks in a row, since the end of one may start another.
        func settle(_ suggestions: ProjectSuggestionService? = nil) async throws {
            let settling = ContinuousClock.now
            var calm = 0
            while calm < 4 {
                try #require(settling.duration(to: .now) < SortingAgainEvaluationTests.settleLimit, "sorting did not finish")
                await runtime.untilResorted()
                await suggestions?.untilNamed()
                let indexing = runtime.projectList.contains { runtime.indexReport($0.id)?.isIndexing == true }
                calm = indexing || runtime.isSorting || suggestions?.isNaming == true ? 0 : calm + 1
                try await Task.sleep(for: .milliseconds(250))
            }
        }

        /// Waits until the index of a project finished a sweep that found files.
        func waitForIndex(_ project: UUID) async throws {
            let waiting = ContinuousClock.now
            while !(runtime.indexReport(project).map { !$0.isIndexing && $0.indexed > 0 } ?? false) {
                try #require(waiting.duration(to: .now) < .seconds(600), "the index did not finish")
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        // MARK: Changes

        /// Dismisses the suggestions TEST_RUNNER_ORRA_PROJECTS_RESORT_DISMISS names, as the
        /// sidebar does.
        func dismiss(in suggestions: ProjectSuggestionService) async throws {
            guard !setup.dismissals.isEmpty else { return }
            await suggestions.refresh()
            await suggestions.untilNamed()
            var dismissed = 0
            for suggestion in suggestions.suggestions where setup.dismissals.contains(Self.anchor(suggestion.group.anchor)) {
                await ProjectsSuggestedSection.dismiss(suggestion, from: suggestions, runtime: runtime).value
                dismissed += 1
            }
            try await settle(suggestions)
            try await record("dismissed suggestions", ["dismissed": dismissed])
        }

        /// Makes a project from Suggested Projects as the window offers it now, saved
        /// unchanged as New Project is prefilled: the suggestion `wanted` names, or without it
        /// the first one whose emails mostly carry the label of a project not made yet.
        /// Without one it makes the project by hand.
        func makeFromSuggestion(_ suggestions: ProjectSuggestionService, wanted: Wanted?) async throws {
            await suggestions.refresh()
            await suggestions.untilNamed()
            let done = Set(slugs.values)
            let shown = suggestions.suggestions.map { (suggestion: $0, label: label(of: $0.group.messageIDs)) }
            let offered = shown.enumerated().map { position, item -> [String: Any] in
                [
                    "position": position + 1, "label": item.label.slug, "share": Self.rounded(item.label.share),
                    "emails": item.suggestion.group.messageIDs.count, "takes": item.suggestion.group.takes.count,
                    "people": item.suggestion.group.people.count, "domains": item.suggestion.group.domains.count,
                    "anchor": Self.kind(item.suggestion.group.anchor), "named": item.suggestion.isNamed,
                ]
            }
            let pick = shown.firstIndex { item in
                if let wanted {
                    return wanted.anchor.map { Self.anchor(item.suggestion.group.anchor) == $0 } ?? (item.label.slug == wanted.slug)
                }
                return item.label.slug != "none" && item.label.slug != "unknown" && !done.contains(item.label.slug)
            }
            guard let pick else {
                let slug = wanted?.slug ?? setup.set.projects.map(\.slug).first(where: { !done.contains($0) })
                let values = try #require(setup.set.projects.first(where: { $0.slug == slug }), "no project is left to make")
                try await makeByHand(values, withFolder: false, offered: offered)
                return
            }
            let suggestion = shown[pick].suggestion
            // The project the edits make of it.
            let slug = wanted?.slug ?? shown[pick].label.slug
            let project = try #require(ProjectsSetupView.Draft(suggestion: suggestion).project, "the prefilled suggestion is not valid")
            try await runtime.add(project)
            suggestions.projectCreated(from: suggestion.id)
            slugs[project.id] = slug
            made.append(["slug": slug, "from": "suggestion \(pick + 1) of \(shown.count)"])
            try await settle(suggestions)
            try await record("made \(slug) from suggestion \(pick + 1)", [
                "slug": slug, "suggestions": offered, "people": project.people.count, "domains": project.domains.count,
            ])
        }

        /// Makes a project by hand with the values of projects.json, as New Project does,
        /// with its folder or without it.
        func makeByHand(_ values: SetLabels.SetProject, withFolder: Bool, offered: [[String: Any]]? = nil) async throws {
            var draft = ProjectsSetupView.Draft()
            try fill(&draft, with: values, withFolder: withFolder)
            let project = try #require(draft.project, "the values of \(values.slug) are not valid")
            try await runtime.add(project)
            slugs[project.id] = values.slug
            made.append(["slug": values.slug, "from": "by hand"])
            if withFolder {
                try await waitForIndex(project.id)
            }
            try await settle()
            var details: [String: Any] = ["slug": values.slug]
            if let offered {
                details["suggestions"] = offered
            }
            try await record("made \(values.slug) by hand", details)
        }

        /// Edits a project to the values of projects.json with its folder, as Edit Project
        /// does, and waits for its index and for sorting.
        func edit(_ id: UUID, _ suggestions: ProjectSuggestionService?) async throws {
            guard let slug = slugs[id], let values = setup.set.projects.first(where: { $0.slug == slug }),
                  let saved = runtime.projectList.first(where: { $0.id == id }) else { return }
            var draft = ProjectsSetupView.Draft(saved)
            try fill(&draft, with: values, withFolder: true)
            let project = try #require(draft.project, "the values of \(slug) are not valid")
            try await runtime.update(project)
            try await waitForIndex(id)
            try await settle(suggestions)
            try await record("edited \(slug) to projects.json", ["slug": slug])
        }

        private func fill(_ draft: inout ProjectsSetupView.Draft, with values: SetLabels.SetProject, withFolder: Bool) throws {
            draft.name = values.name
            draft.description = values.description
            draft.people = values.people.map { entry in
                let person = MailAddressHeader.list(entry).first
                return ProjectsSetupView.Draft.Person(name: person?.name ?? "", address: person?.address ?? entry)
            }
            draft.domains = values.domains.joined(separator: ", ")
            draft.folders = []
            if withFolder {
                let bookmark = try Project.bookmark(of: setup.set.folder(of: values, in: setup.root))
                draft.folders = [ProjectsSetupView.Draft.Folder(bookmark: bookmark)]
            }
            draft.mailbox = nil
            draft.otherMailboxes = []
        }

        // MARK: What it measured

        /// Where each email of the set is now, by the set's id.
        func placements() async throws -> [String: Placement] {
            var places: [(MailStore.Place, String)] = [(.needsProject, "needsProject"), (.setAside, "setAside")]
            for project in runtime.projectList {
                places.append((.project(project.id), slugs[project.id] ?? "unknown"))
            }
            var found: [String: Placement] = [:]
            for (place, name) in places {
                for row in try await runtime.list(place) {
                    found[setup.set.id(of: row.messageID)] = Placement(
                        place: name, level: row.level?.rawValue ?? "notSorted", reasons: row.reasons.map(\.rawValue), movedByUser: row.movedByUser)
                }
            }
            return found
        }

        /// Notes the counts after a step, with the model's jobs and the time since the step
        /// before, and writes the run so far.
        func record(_ step: String, _ details: [String: Any] = [:]) async throws {
            let placements = try await placements()
            let counts = Self.counts(setup.set, placements)
            let now = jobs.counts
            var row: [String: Any] = [
                "step": step,
                "seconds": Self.rounded(stepStarted.duration(to: .now) / .seconds(1)),
                "sorting_jobs": now.sorting - jobsBefore.sorting,
                "naming_jobs": now.naming - jobsBefore.naming,
                "right": counts.right, "wrong": counts.wrong, "waiting": counts.waiting,
                "wrong_ids": counts.wrongIDs,
            ]
            row.merge(details) { _, new in new }
            steps.append(row)
            jobsBefore = now
            stepStarted = .now
            try write(placements)
        }

        /// Writes the run, prints its counts and gives them back.
        func finish() async throws -> Result {
            let placements = try await placements()
            try write(placements)
            let counts = Self.counts(setup.set, placements)
            let now = jobs.counts
            print("Sorting again, \(name): \(counts.right) right, \(counts.wrong) wrong, \(counts.waiting) waiting of \(setup.set.ids.count), \(now.sorting) sorting jobs and \(now.naming) naming jobs, \(Self.rounded(started.duration(to: .now) / .seconds(1))) s. Rows in \(name).json.")
            return Result(right: counts.right, wrong: counts.wrong, waiting: counts.waiting, missing: setup.set.ids.count - placements.count)
        }

        /// Turns Projects off with its data, lets the model go and removes the run's files.
        func stop() async {
            runtime.windowClosed()
            await projects.turnOff(keepingData: false)
            let stopping = ContinuousClock.now
            while runtime.phase != .off, stopping.duration(to: .now) < .seconds(60) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await engine.unload()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }

        private func write(_ placements: [String: Placement]) throws {
            var mails: [[String: Any]] = []
            var wrong: [[String: Any]] = []
            var waiting: [[String: Any]] = []
            for id in setup.set.ids {
                let label = setup.set.labels[id] ?? "none"
                let placement = placements[id]
                let place = placement?.place ?? "missing"
                let outcome = SortingAgainEvaluationTests.outcome(label: label, place: place)
                let row: [String: Any] = [
                    "id": id, "label": label, "place": place, "level": placement?.level ?? "missing",
                    "reasons": placement?.reasons ?? [], "moved_by_user": placement?.movedByUser ?? false, "outcome": outcome.rawValue,
                ]
                mails.append(row)
                switch outcome {
                case .wrong: wrong.append(row)
                case .waiting: waiting.append(row)
                case .right: break
                }
            }
            let counts = Self.counts(setup.set, placements)
            let now = jobs.counts
            let document: [String: Any] = [
                "run": name,
                "build": GateOutput.build,
                "device": SpeechCorpus.chip(),
                "today": "2026-10-25",
                "order": setup.order.map { $0.anchor == nil ? $0.slug : $0.slug + " by its anchor" },
                "dismissed_anchors": setup.dismissals.count,
                "made": made,
                "right": counts.right,
                "wrong": counts.wrong,
                "waiting": counts.waiting,
                "missing": setup.set.ids.count - placements.count,
                "bar_wrong": SortingAgainEvaluationTests.bar,
                "wrong_mails": wrong,
                "waiting_mails": waiting,
                "steps": steps,
                "model_jobs": ["sorting": now.sorting, "naming": now.naming, "other": now.other, "seconds": Self.rounded(now.seconds)],
                "seconds": Self.rounded(started.duration(to: .now) / .seconds(1)),
                "mails": mails,
            ]
            try FileManager.default.createDirectory(at: setup.out, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: setup.out.appendingPathComponent("\(name).json"))
        }

        /// The label most of these emails carry, with its share of them.
        private func label(of messageIDs: [String]) -> (slug: String, share: Double) {
            var counts: [String: Int] = [:]
            for messageID in messageIDs {
                counts[setup.set.labels[setup.set.id(of: messageID)] ?? "unknown", default: 0] += 1
            }
            guard let best = counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).first else { return ("unknown", 0) }
            return (best.key, Double(best.value) / Double(messageIDs.count))
        }

        private static func counts(_ set: SetLabels, _ placements: [String: Placement]) -> (right: Int, wrong: Int, waiting: Int, wrongIDs: [String]) {
            var counts: [Outcome: Int] = [:]
            var wrongIDs: [String] = []
            for id in set.ids {
                let outcome = SortingAgainEvaluationTests.outcome(label: set.labels[id] ?? "none", place: placements[id]?.place ?? "missing")
                counts[outcome, default: 0] += 1
                if outcome == .wrong {
                    wrongIDs.append(id)
                }
            }
            return (counts[.right] ?? 0, counts[.wrong] ?? 0, counts[.waiting] ?? 0, wrongIDs)
        }

        /// The value an anchor holds, lowercased: a domain, an address, a word or a mailbox.
        private static func anchor(_ anchor: ProjectSuggestions.Anchor) -> String {
            switch anchor {
            case .domain(let value), .person(let value), .word(let value), .mailbox(let value): value.lowercased()
            }
        }

        /// What kind of anchor holds a group, without its value.
        private static func kind(_ anchor: ProjectSuggestions.Anchor) -> String {
            switch anchor {
            case .domain: "domain"
            case .person: "person"
            case .word: "word"
            case .mailbox: "mailbox"
            }
        }

        private static func rounded(_ value: Double) -> Double {
            (value * 100).rounded() / 100
        }
    }

    // MARK: The model and Mail

    /// Counts the model's jobs by what asked for them, told apart by the most answer tokens
    /// each asks for: sorting an email or naming a suggestion. Adds up the time from the
    /// start of each job to its end.
    nonisolated final class ModelJobs: Sendable {
        nonisolated struct Counts: Sendable {
            var sorting = 0
            var naming = 0
            var other = 0
            var seconds = 0.0
        }

        private nonisolated struct State: Sendable {
            var counts = Counts()
            var running: [Int: ContinuousClock.Instant] = [:]
        }

        private let state = Mutex(State())

        var counts: Counts {
            state.withLock { $0.counts }
        }

        /// The model's closures for ProjectsModelQueue, as the app gives them, with nothing
        /// to wait for, counting each job.
        @MainActor func environment(_ engine: CleanupEngine) -> ProjectsModelEnvironment {
            let start = engine.startJob
            let end = engine.endJob
            let sortingTokens = SortingPrompt.maximumTokens
            let namingTokens = ProjectSuggestionPrompt.maximumTokens
            return ProjectsModelEnvironment(
                startJob: { [self] prompt, tokens in
                    let began = ContinuousClock.now
                    let job = try await start(prompt, tokens)
                    state.withLock { state in
                        switch tokens {
                        case sortingTokens: state.counts.sorting += 1
                        case namingTokens: state.counts.naming += 1
                        default: state.counts.other += 1
                        }
                        state.running[job.id] = began
                    }
                    return job
                },
                readSlice: engine.readSlice,
                writeBurst: engine.writeBurst,
                endJob: { [self] id in
                    defer {
                        state.withLock { state in
                            if let began = state.running.removeValue(forKey: id) {
                                state.counts.seconds += began.duration(to: .now) / .seconds(1)
                            }
                        }
                    }
                    return try await end(id)
                },
                isDictating: { false },
                captionsOn: { false },
                memoryPressure: { .normal },
                voiceLoaded: { false },
                physicalMemory: ProcessInfo.processInfo.physicalMemory,
                waitUntilLoaded: { true },
                holdModel: {},
                releaseModel: {},
                sleep: { try await Task.sleep(for: $0) }
            )
        }
    }

    /// Mail as the evaluation plays it: one mailbox On My Mac that holds the messages of an
    /// mbox file, as Mail imports it, listed newest first. It never sends an Apple Event.
    nonisolated final class SetMailbox: Sendable {
        nonisolated struct Message: Sendable {
            let listing: MailListing
            let source: String
        }

        static let mailbox = MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, "orra-test", of: .application), name: "orra-test", account: nil)

        let messages: [Message]

        init(mbox: URL) throws {
            let read = Self.sources(try String(contentsOf: mbox, encoding: .utf8)).enumerated().map { position, source in
                (position: position, headers: MailHeaders(parsing: Self.head(of: source)), source: source)
            }
            let newestFirst = read.sorted { first, second in
                let firstDate = first.headers.date ?? .distantPast
                let secondDate = second.headers.date ?? .distantPast
                return firstDate == secondDate ? first.position > second.position : firstDate > secondDate
            }
            messages = newestFirst.enumerated().map { position, item in
                let from = item.headers.from.first
                return Message(
                    listing: MailListing(
                        message: MailMessageRef(id: position + 1, mailbox: Self.mailbox),
                        messageID: item.headers.messageID ?? "",
                        dateReceived: item.headers.date,
                        sender: from.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" } ?? "",
                        subject: item.headers.subject ?? "",
                        to: item.headers.to.compactMap { ProjectsAddress.normalized($0.address) },
                        cc: item.headers.cc.compactMap { ProjectsAddress.normalized($0.address) },
                        size: item.source.utf8.count),
                    source: item.source)
            }
        }

        var bridge: MailBridge {
            let messages = messages
            let mailbox = Self.mailbox
            return MailBridge(
                isRunning: { true },
                permission: { _ in .allowed },
                lastPermission: { .allowed },
                accounts: { throw MailBridgeError.failed(code: -1) },
                mailboxes: { [mailbox] },
                count: { $0 == mailbox ? messages.count : 0 },
                listing: { box, positions in
                    guard box == mailbox else { return [] }
                    guard positions.lowerBound >= 1, positions.upperBound <= messages.count else { throw MailBridgeError.notFound }
                    return messages[(positions.lowerBound - 1)..<positions.upperBound].map(\.listing)
                },
                headers: { reference in try Self.head(of: Self.message(reference, in: messages).source) },
                source: { reference in try Self.message(reference, in: messages).source },
                attachments: { _ in [] },
                mailbox: { _ in throw MailBridgeError.notFound },
                selection: { [] },
                reply: { _, _ in throw MailBridgeError.unexpectedReply },
                attach: { _, _ in throw MailBridgeError.unexpectedReply }
            )
        }

        private static func message(_ reference: MailMessageRef, in messages: [Message]) throws -> Message {
            guard let message = messages.first(where: { $0.listing.message == reference }) else { throw MailBridgeError.notFound }
            return message
        }

        /// The messages of an mbox file, each as Mail gives its source: the lines between two
        /// From lines, with the > taken off a line the file marked so it never reads as one,
        /// and a line feed at the end.
        static func sources(_ text: String) -> [String] {
            var sources: [String] = []
            var lines: [Substring] = []
            func finish() {
                while lines.last?.isEmpty == true {
                    lines.removeLast()
                }
                if !lines.isEmpty {
                    sources.append(lines.joined(separator: "\n") + "\n")
                }
                lines = []
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("From ") {
                    finish()
                } else {
                    lines.append(line.hasPrefix(">From ") ? line.dropFirst() : line)
                }
            }
            finish()
            return sources
        }

        /// The headers of a source, up to the first empty line.
        static func head(of source: String) -> String {
            source.range(of: "\n\n").map { String(source[..<$0.lowerBound]) } ?? source
        }
    }
}
