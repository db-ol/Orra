import Foundation
import Observation

/// The files of a reply in the email view, which ProjectsEmailModel owns:
/// - the files each request of the explanation may mean, see RequestedFiles, looked for
///   when the email view reads a new explanation and on Look Again, never during a
///   dictation. A file found for an earlier request shows there only.
/// - the files the user ticked for the reply, in the order ticked, each once by its real
///   path. Nothing is ticked by default, after Explain Again or from another email, and at
///   most `ReplyFiles.maximum` are. Each tick checks the file, see
///   ProjectsRuntime.replyFile(at:first:), and a file that cannot go keeps its reason.
/// - Add File… and dropped files, which take only files the index holds in the folders the
///   user added to a project.
/// - the people a reply reaches outside the projects of a ticked file, and whether the draft
///   says a file is attached while none is ticked.
///
/// A sender that looks spoofed, by a lookalike domain or a name that does not match its
/// address, gets no files at all: no search, no tick and no file for the handoff. An email
/// whose own checks found a warning of `ExplainService.otherProjectWarnings`, in the email or
/// its attachments, gets files of its own project only, and none in no project, as Explain
/// gives it no other project's passage. A finding in a project file, the thread or the
/// project's other mail is about that text, not the email, see `scopeWarnings(_:listed:)`.
/// Mail set aside gets no search, as it gets no files in Explain either.
///
/// The ticks live in memory only, for as long as the window keeps the email view: they go
/// when the window closes, when Forget Project or Projects turning off lets go of the email
/// views, and when the email has no explanation any more. Explain Again keeps them. Nothing
/// here logs.
@Observable
final class ProjectsReplyFiles {
    /// What the files of a reply need of the runtime. Closures, so tests pass fakes. The
    /// defaults find and take nothing, for tests that never tick a file.
    struct Actions {
        /// The files a request may mean, see ProjectsRuntime.requestedFiles(for:emailProject:scope:).
        var requestedFiles: (FileRequest, _ emailProject: UUID?, _ scope: [UUID]?) async -> [RequestedFile] = { _, _, _ in [] }
        /// A file the user ticks or adds, see ProjectsRuntime.replyFile(at:first:).
        var replyFile: (URL, _ emailProject: UUID?) async -> Result<ReplyFile, ReplyFileProblem> = { _, _ in .failure(.notInAddedFolder) }
        /// A ticked file checked again right before its attach event, see
        /// ProjectsRuntime.recheck(_:).
        var recheck: @Sendable (ReplyFile) async -> Result<ReplyFile, ReplyFileProblem> = { _ in .failure(.notInAddedFolder) }
        /// The projects as an explanation knows them, for the people outside a file's project.
        var replyProjects: () -> [ExplainService.Project] = { [] }
        /// Where Add File… starts, see ProjectsRuntime.defaultFolder(of:).
        var defaultFolder: (UUID?) async -> URL? = { _ in nil }
        /// The email as its list shows it, for the warnings of its list and whether it was set
        /// aside.
        var listed: (String) async -> MailStore.Listed? = { _ in nil }

        /// The actions of the running app.
        static func live(_ runtime: ProjectsRuntime) -> Actions {
            Actions(
                requestedFiles: { [weak runtime] request, project, scope in
                    await runtime?.requestedFiles(for: request, emailProject: project, scope: scope) ?? []
                },
                replyFile: { [weak runtime] url, project in
                    await runtime?.replyFile(at: url, first: project) ?? .failure(.notInAddedFolder)
                },
                recheck: { [weak runtime] file in
                    await runtime?.recheck(file) ?? .failure(.notInAddedFolder)
                },
                replyProjects: { [weak runtime] in runtime?.replyProjects() ?? [] },
                defaultFolder: { [weak runtime] project in await runtime?.defaultFolder(of: project) },
                listed: { [weak runtime] id in await runtime?.listed(id) }
            )
        }
    }

    /// A request of the explanation with the files found for it, nil while they are looked
    /// for.
    struct Group: Equatable, Identifiable {
        /// Its place among the requests, from 0.
        var id: Int
        var request: FileRequest
        var files: [RequestedFile]?
    }

    /// Where the files of a request are looked for.
    nonisolated enum Scope: Equatable, Sendable {
        /// The folders of every project, the email's first.
        case everyProject
        /// The email's project only, for an email with a warning that keeps other projects
        /// out.
        case ownProject(UUID)
        /// Nowhere: a flagged email in no project.
        case nowhere
        /// Nowhere, since the sender may not be who they claim to be.
        case spoofed
    }

    /// Why a file the user chose with Add File… or dropped was not added.
    nonisolated struct Refusal: Hashable, Sendable {
        var problem: ReplyFileProblem
        /// The file's name, for a file that is not on this Mac.
        var name: String
    }

    private let messageID: String
    private let actions: Actions

    /// The facts of the reply the explanation saved, nil before 0.6.1 and without a reply due.
    private(set) var facts: Explanation.ReplyFacts?
    /// The email's project, as its explanation has it.
    private(set) var emailProject: UUID?
    /// Whether a reply is due, so the view offers files for it.
    private(set) var replyIsDue = false
    /// The addresses a reply to all reaches, the user's own left out: those of the facts, or
    /// those of the draft check for an explanation without facts.
    private(set) var recipients: [String] = []
    /// The warnings about the email itself, from its explanation and its list, see
    /// `scopeWarnings(_:listed:)`.
    private(set) var warnings: Set<ProjectsWarning> = []
    /// Whether sorting set the email aside.
    private(set) var isSetAside = false
    /// The requests of the explanation with their files.
    private(set) var groups: [Group] = []
    /// Whether files are looked for.
    private(set) var isLooking = false
    /// The files ticked for the reply, in the order ticked.
    private(set) var ticked: [ReplyFile] = []
    /// The paths whose tick waits for its check, which show ticked meanwhile.
    private(set) var checking: Set<String> = []
    /// Why a file cannot go into the reply, by the path it was ticked at: from its tick, or
    /// from its check right before its attach event.
    private(set) var problems: [String: ReplyFileProblem] = [:]
    /// Why files chosen with Add File… or dropped were not added, the last choice's.
    private(set) var refusals: [Refusal] = []
    /// Whether a tick went past `ReplyFiles.maximum`, until a file goes.
    private(set) var reachedCap = false
    /// Whether the draft says a file is attached while no file is ticked, see
    /// DraftCheck.attachmentClaims(in:).
    private(set) var claimsAttachment = false
    /// The requests the files were last looked for, and the scope, so a load that changes
    /// neither looks for nothing.
    @ObservationIgnored private var lookedFor: ([FileRequest], Scope)?
    @ObservationIgnored private var looking: Task<Void, Never>?
    /// The draft as the claim was last read in.
    @ObservationIgnored private var draftText = ""

    init(messageID: String, actions: Actions) {
        self.messageID = messageID
        self.actions = actions
    }

    // MARK: What the view reads

    /// Whether the sender looks spoofed, by a lookalike domain or a name that does not
    /// match its address, among the explanation's warnings or its list's.
    var senderLooksSpoofed: Bool {
        Self.looksSpoofed(warnings)
    }

    /// Where the files of a request are looked for.
    var scope: Scope {
        Self.scope(warnings: warnings, emailProject: emailProject)
    }

    /// The warnings that say the sender may not be who they claim to be.
    nonisolated static let spoofWarnings: Set<ProjectsWarning> = [.lookalikeDomain, .senderNameMismatch]

    /// Whether the warnings say the sender may not be who they claim to be.
    nonisolated static func looksSpoofed(_ warnings: Set<ProjectsWarning>) -> Bool {
        !warnings.isDisjoint(with: spoofWarnings)
    }

    /// The warnings about the email itself, which decide where the files of a request are
    /// looked for: what the checks of the explanation found in the email and its attachments,
    /// as Explain finds them before its search, see ExplainService.retrievalWarnings, and a
    /// sender that the list's warnings say may not be who they claim. A finding in a project
    /// file, a message of the thread or the project's other mail is about that text, not
    /// about the email, so it keeps no project out. The list holds every kind that any
    /// explanation of the email found, wherever it was, so only its kinds about the sender
    /// count. The opt in FileRequestEvaluationTests reads it too.
    nonisolated static func scopeWarnings(_ found: [ExplainPrompt.Finding], listed: [ProjectsWarning]) -> Set<ProjectsWarning> {
        Set(found.filter(\.place.isTheEmail).map(\.warning)).union(listed.filter(spoofWarnings.contains))
    }

    /// Where the files of a request are looked for, by the warnings about the email, see
    /// `scopeWarnings(_:listed:)`: nowhere for a sender that looks spoofed, the email's
    /// project only for a warning that keeps other projects out, see
    /// ExplainService.otherProjectWarnings, and every project otherwise. The opt in
    /// FileRequestEvaluationTests reads it too.
    nonisolated static func scope(warnings: Set<ProjectsWarning>, emailProject: UUID?) -> Scope {
        if looksSpoofed(warnings) { return .spoofed }
        guard !warnings.isDisjoint(with: ExplainService.otherProjectWarnings) else { return .everyProject }
        return emailProject.map(Scope.ownProject) ?? .nowhere
    }

    /// Whether files can be ticked for the reply: a reply is due and the sender does not
    /// look spoofed.
    var offersFiles: Bool {
        replyIsDue && !senderLooksSpoofed
    }

    /// Whether the email asks for files, so Files This Email Asks For shows.
    var hasRequests: Bool {
        !groups.isEmpty
    }

    /// Whether the line that Projects does not know the sender shows.
    var senderIsUnknown: Bool {
        facts.map { !$0.senderIsKnown } ?? false
    }

    /// Whether a file shows ticked: ticked, or its tick waits for its check.
    func isTicked(_ url: URL) -> Bool {
        checking.contains(url.path) || ticked.contains { $0.url.path == url.path }
    }

    /// Why a file the user ticked at this path cannot go, nil when it can.
    func problem(at url: URL) -> ReplyFileProblem? {
        problems[url.path]
    }

    /// The files for a handoff: none for a sender that looks spoofed.
    var handoffFiles: [ReplyFile] {
        senderLooksSpoofed ? [] : ticked
    }

    /// Whether a file a handoff took at the click is still among `handoffFiles`, by what
    /// makes it that file, so a file a check followed to its new name counts too. One the
    /// user took off the reply, and every file once the sender looks spoofed, does not.
    func isStillTicked(_ file: ReplyFile) -> Bool {
        handoffFiles.contains { $0.identity == file.identity }
    }

    /// The people a reply to all reaches who are neither people of any project whose
    /// folders hold the file nor at their domains, see ReplyFiles.outside.
    func outside(of file: ReplyFile) -> [String] {
        ReplyFiles.outside(of: file, recipients: recipients, projects: actions.replyProjects())
    }

    /// The name of a project the list holds, for the line of a file of another project.
    func projectName(_ id: UUID) -> String? {
        actions.replyProjects().first { $0.id == id }?.name
    }

    /// Whether the ticked files add up to more than many mail servers take.
    var areLarge: Bool {
        ReplyFiles.areLarge(ticked)
    }

    // MARK: The explanation

    /// Takes the explanation as the email view read it. Without one the ticks and all else
    /// go, as after a move to another project. A new explanation, as after Explain Again,
    /// keeps the ticks and looks for the files of its requests again.
    func explanationChanged(_ explanation: Explanation?) async {
        guard let explanation else {
            clear()
            return
        }
        let facts = explanation.replyFacts
        if facts != self.facts {
            self.facts = facts
        }
        emailProject = explanation.project
        if case .reply = explanation.reply {
            replyIsDue = true
        } else {
            replyIsDue = false
        }
        recipients = facts?.replyAll ?? (explanation.draftCheck?.recipients ?? []).map { ProjectsAddress.normalized($0.address) ?? $0.address.lowercased() }
        let listed = await actions.listed(messageID)
        let warnings = Self.scopeWarnings(explanation.warnings, listed: listed?.warnings ?? [])
        if warnings != self.warnings {
            self.warnings = warnings
        }
        isSetAside = listed?.level == .setAside
        if senderLooksSpoofed, !ticked.isEmpty {
            ticked = []
        }
        let requests = replyIsDue && !isSetAside ? facts?.requests ?? [] : []
        if lookedFor.map({ $0.0 != requests || $0.1 != scope }) ?? true {
            lookForFiles(requests)
        }
        readClaims()
    }

    /// Look Again: looks for the files of the requests once more, such as after Projects
    /// read a new folder.
    func lookAgain() {
        lookForFiles(groups.map(\.request))
    }

    /// Looks for the files of each request in turn, in a task of its own that a new look or
    /// `cancel()` ends.
    private func lookForFiles(_ requests: [FileRequest]) {
        looking?.cancel()
        let scope = scope
        lookedFor = (requests, scope)
        groups = requests.enumerated().map { Group(id: $0.offset, request: $0.element, files: nil) }
        guard !requests.isEmpty else {
            isLooking = false
            return
        }
        isLooking = true
        let project = emailProject
        looking = Task { [weak self, actions] in
            var shown: Set<String> = []
            for (index, request) in requests.enumerated() {
                var files: [RequestedFile] = []
                switch scope {
                case .everyProject:
                    files = await actions.requestedFiles(request, project, nil)
                case .ownProject(let own):
                    files = await actions.requestedFiles(request, project, [own])
                case .nowhere, .spoofed:
                    break
                }
                guard !Task.isCancelled, let self else { return }
                // A file found for an earlier request shows there only.
                files.removeAll { shown.contains($0.id) }
                shown.formUnion(files.map(\.id))
                if self.groups.indices.contains(index) {
                    self.groups[index].files = files
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.isLooking = false
        }
    }

    /// Ends the look under way, such as when the window closes.
    func cancel() {
        looking?.cancel()
        looking = nil
        isLooking = false
        lookedFor = nil
    }

    /// Lets go of everything, as for an email without an explanation.
    private func clear() {
        cancel()
        facts = nil
        emailProject = nil
        replyIsDue = false
        recipients = []
        warnings = []
        isSetAside = false
        groups = []
        ticked = []
        checking = []
        problems = [:]
        refusals = []
        reachedCap = false
        claimsAttachment = false
    }

    // MARK: Ticks

    /// Ticks or unticks the file at a URL, from Files This Email Asks For or from Project
    /// Files for This Explanation. A tick checks the file first, which shows ticked
    /// meanwhile, and keeps its reason when it cannot go.
    func setTicked(_ url: URL, _ isTicked: Bool) async {
        guard isTicked else {
            untick(url.path)
            return
        }
        _ = await take(url)
    }

    /// Adds files chosen with Add File… or dropped on the area, each checked as a tick is.
    /// Those that cannot go are listed as refused, each reason once.
    func add(_ urls: [URL]) async {
        refusals = []
        for url in urls {
            guard let problem = await take(url) else { continue }
            let refusal = Refusal(problem: problem, name: url.lastPathComponent)
            if problem == .notDownloaded ? !refusals.contains(refusal) : !refusals.contains(where: { $0.problem == problem }) {
                refusals.append(refusal)
            }
            problems[url.path] = nil
        }
    }

    /// Remove: takes a ticked file off the reply.
    func remove(_ file: ReplyFile) {
        untick(file.url.path)
    }

    /// Ticks a file once its check passed, and gives the reason when it cannot go. Nothing
    /// for a sender that looks spoofed, and nothing past the cap.
    private func take(_ url: URL) async -> ReplyFileProblem? {
        guard offersFiles, !isTicked(url) else { return nil }
        guard ticked.count + checking.count < ReplyFiles.maximum else {
            reachedCap = true
            return nil
        }
        checking.insert(url.path)
        let result = await actions.replyFile(url, emailProject)
        checking.remove(url.path)
        switch result {
        case .success(let file):
            // The sender may look spoofed by now, as after Explain Again.
            guard offersFiles else { return nil }
            problems[url.path] = nil
            guard !ticked.contains(where: { $0.url.path == file.url.path }) else { return nil }
            guard ticked.count < ReplyFiles.maximum else {
                reachedCap = true
                return nil
            }
            ticked.append(file)
            readClaims()
            return nil
        case .failure(let problem):
            problems[url.path] = problem
            return problem
        }
    }

    private func untick(_ path: String) {
        ticked.removeAll { $0.url.path == path }
        problems[path] = nil
        if ticked.count < ReplyFiles.maximum {
            reachedCap = false
        }
        readClaims()
    }

    /// What the check right before a file's attach event found: a file at a new place after
    /// a rename stays ticked at that place, and one that cannot go keeps its reason.
    func checked(_ file: ReplyFile, _ result: Result<ReplyFile, ReplyFileProblem>) {
        switch result {
        case .success(let now):
            guard now.url.path != file.url.path, let index = ticked.firstIndex(where: { $0.url.path == file.url.path }) else { return }
            ticked[index] = now
        case .failure(let problem):
            problems[file.url.path] = problem
        }
    }

    // MARK: The claim of the draft

    /// Reads the draft once typing paused, see ProjectsEmailModel.saveText(), for a sentence
    /// that says a file is attached while no file is ticked. It never changes the draft.
    func readClaims(in text: String) {
        draftText = text
        readClaims()
    }

    private func readClaims() {
        let claims = offersFiles && ticked.isEmpty && !DraftCheck.attachmentClaims(in: draftText).isEmpty
        if claims != claimsAttachment {
            claimsAttachment = claims
        }
    }

    /// Where Add File… starts: the first folder of the email's project.
    func defaultFolder() async -> URL? {
        await actions.defaultFolder(emailProject)
    }
}
