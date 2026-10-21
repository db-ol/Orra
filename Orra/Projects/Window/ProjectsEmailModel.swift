import Foundation
import Observation

/// One email in the email view of the Projects window (projects-email-view): its
/// explanation, the versions of its draft, the draft as the user edits it, the translation
/// next to it, the answer check, the change under way and the handoff to Mail.
///
/// - The draft is plain text the user may edit. Only the versions the model makes are saved,
///   by ReviseService. The user's own edits stay in memory while the window is open, so
///   they last while the user looks at other mail, and go when the window closes, Projects
///   stops or a project is forgotten, see ProjectsWindowModel.
/// - A change, from the change box or a tone, makes a new version of the draft as the
///   editor holds it, checked by DraftCheck. Undo removes the newest version and puts back
///   the text it was made from.
/// - The answer check runs on its own once for each draft the model makes while the window
///   is open: after the explanation, see ProjectsWindowModel.explain(_:), and after each new
///   version (decision 9). For a draft made in an earlier window, and after an edit, it runs
///   on a click. The translation runs while Show in My Language is on, for each version, and
///   on a click after an edit.
/// - The talk key's words go straight into the change box while it has the focus, and change
///   the draft as soon as the dictation ends while the setting for it is on (decision 13),
///   see `takeDictation(_:revises:)`.
/// - Open Reply in Mail and Reply All need Mail's handle of the email, which the scan keeps
///   for this Mail session, and headers from Mail that show the message under it is this
///   email. Without them the draft is only copied. The window runs one handoff at a time,
///   for all its emails, see `Handoffs`.
///
/// Every request of the model runs through ProjectsModelQueue as one of the user's, inside
/// ProjectsRuntime.userRequest(_:), so turning Projects off ends it. The requests started
/// with `perform(_:)` end when the window closes, see `cancelWork()`. Nothing here logs.
@Observable
final class ProjectsEmailModel {
    /// What the email view does with the runtime. Closures, so tests pass fakes.
    struct Actions {
        /// The email's latest explanation, nil when there is none.
        var explanation: (String) async -> Explanation?
        /// The versions of the email's draft, oldest first.
        var versions: (String) async -> [MailStore.DraftVersion]
        /// Removes the newest version, and says whether there was one.
        var removeNewestVersion: (String) async -> Bool
        /// What a revision checks with, nil when the explanation has no draft to change.
        var reviseContext: (Explanation) async -> ReviseService.Context?
        /// A service for one request on the draft, started at this time, see
        /// ProjectsRuntime.reviseService(startedAt:).
        var reviseService: (Date) async throws -> ReviseService
        /// Runs a request on the draft as one of the user's, see
        /// ProjectsRuntime.userRequest(_:).
        var userRequest: (@escaping @MainActor () async throws -> Void) async throws -> Void
        /// An email the store holds, for the source chips and the text of this email.
        var email: (String) async -> ExplainService.Email?
        /// Mail's handle of an email in this Mail session, for a reply or with the flag a
        /// reply to all, once Mail confirmed that the message under it is the email, see
        /// ProjectsRuntime.checkedMailReference(for:all:). Nil when there is none. Throws
        /// what Mail answered when it could not check.
        var mailReference: (_ messageID: String, _ all: Bool) async throws -> MailMessageRef?
        var handoff: ReplyHandoff
        /// The language the user reads explanations in.
        var userLanguage: ProjectsLanguage
        var now: () -> Date

        /// The actions of the running app.
        static func live(_ runtime: ProjectsRuntime) -> Actions {
            Actions(
                explanation: { [weak runtime] id in await runtime?.explanation(for: id) },
                versions: { [weak runtime] id in await runtime?.versions(of: id) ?? [] },
                removeNewestVersion: { [weak runtime] id in await runtime?.removeNewestVersion(of: id) ?? false },
                reviseContext: { [weak runtime] explanation in await runtime?.reviseContext(for: explanation) },
                reviseService: { [weak runtime] started in
                    guard let runtime else { throw ProjectsRuntime.Failure.off }
                    return try await runtime.reviseService(startedAt: started)
                },
                userRequest: { [weak runtime] work in
                    guard let runtime else { throw ProjectsRuntime.Failure.off }
                    try await runtime.userRequest(work)
                },
                email: { [weak runtime] id in await runtime?.email(id) },
                mailReference: { [weak runtime] id, all in try await runtime?.checkedMailReference(for: id, all: all) },
                handoff: runtime.handoff,
                userLanguage: runtime.userLanguage,
                now: runtime.dependencies.now
            )
        }
    }

    /// What a source id of a point stands for, as its chip shows it.
    nonisolated enum Source: Equatable, Sendable {
        /// The email itself.
        case thisEmail
        /// Another email, which the window can show. Its sender and date are nil when the
        /// store no longer holds it.
        case mail(messageID: String, sender: String?, date: Date?)
        /// The excerpt of a project file the model read.
        case file(TextChunker.Chunk)
    }

    /// Why a change, a translation or the answer check gave nothing new.
    nonisolated enum Note: Equatable, Sendable {
        /// The cleanup model is not on this Mac, or the window closed.
        case noModel
        /// The draft or the change does not fit into a prompt.
        case tooLong
        /// The model wrote nothing that can be used, or was cut short.
        case noAnswer
        /// The new version came back in another language, so the draft stays.
        case heldBack
        /// The email was explained again or moved meanwhile, so the new version was not kept.
        case notKept
        case emptyDraft
        case other
    }

    /// What the last handoff did.
    nonisolated enum HandoffNote: Equatable, Sendable {
        case outcome(ReplyHandoff.Outcome)
        /// Mail's handle of the email is not known in this Mail session, so no reply opened
        /// and the draft was only copied.
        case messageNotFound
    }

    /// A translation of a draft, for the draft it was made from.
    struct Translation: Equatable {
        var draft: String
        /// The translation, or the draft itself when it is in the user's language already.
        var text: String
    }

    /// The answer check of a draft, for the draft it was made from.
    struct Answers: Equatable {
        var draft: String
        var answers: ReviseService.Answers
    }

    /// The handoffs of one window. One runs at a time for all its emails, so the clipboard
    /// holds the draft of the reply window that Mail brings forward (#143).
    @Observable
    final class Handoffs {
        /// Whether a handoff runs, so Open Reply in Mail, Reply All and Copy wait.
        fileprivate(set) var isRunning = false
    }

    /// The newest version with what it changed, for its highlight and Undo.
    struct LastChange: Equatable {
        var version: MailStore.DraftVersion
        var segments: [ProjectsDraftDiff.Segment]
    }

    let messageID: String
    private let actions: Actions
    /// The window's handoffs, which this email's handoff waits for.
    let handoffs: Handoffs

    /// Whether the explanation and the versions were read once.
    private(set) var isLoaded = false
    private(set) var explanation: Explanation?
    /// The versions the model made after the explanation's draft, oldest first.
    private(set) var versions: [MailStore.DraftVersion] = []
    /// The newest version with what it changed, for its highlight and Undo: from the text it
    /// was made from, or from the draft before it. Worked out off the main actor when the
    /// versions change, never at a key press in the editor.
    private(set) var lastChange: LastChange?
    /// What each source id of the explanation stands for.
    private(set) var sources: [String: Source] = [:]
    /// The email's own text, for the chip of this email.
    private(set) var emailText = ""
    /// The draft as the editor holds it.
    var text = ""
    /// What the user types or says into the change box. The talk key writes here too, see
    /// `takeDictation(_:revises:)`.
    var instruction = ""
    /// Whether the change box has the focus in the window, which the view sets. The talk
    /// key's words go there only then.
    @ObservationIgnored var changeBoxHasFocus = false
    /// The change under way, nil while none runs.
    private(set) var changing: RevisePrompt.Change?
    private(set) var changeNote: Note?
    private(set) var isUndoing = false
    /// Whether Show in My Language is on.
    private(set) var showsTranslation = false
    private(set) var translation: Translation?
    private(set) var isTranslating = false
    private(set) var translationNote: Note?
    private(set) var answers: Answers?
    private(set) var isCheckingAnswers = false
    private(set) var answersNote: Note?
    private(set) var handoffNote: HandoffNote?
    /// The text each saved version was made from, by its number, for the highlight and
    /// Undo. Only for the versions made while the window is open.
    @ObservationIgnored private var madeFrom: [Int: String] = [:]
    /// Whether a translation or an answer check was asked for while one ran.
    @ObservationIgnored private var translateAgain = false
    @ObservationIgnored private var checkAgain = false
    /// Whether the talk key's words came into the change box, with the change after a
    /// dictation on, while a change or an undo ran, so the draft changes with them once that
    /// ends.
    @ObservationIgnored private var changesWhenFree = false
    /// The requests started with `perform(_:)` that still run.
    @ObservationIgnored private var work: [UUID: Task<Void, Never>] = [:]

    init(messageID: String, actions: Actions, handoffs: Handoffs = Handoffs()) {
        self.messageID = messageID
        self.actions = actions
        self.handoffs = handoffs
    }

    // MARK: What the view reads

    /// What DraftCheck found in the newest draft the model made: the newest version's, or
    /// the explanation's for its first draft.
    var draftCheck: DraftCheck.Result? {
        if let last = versions.last {
            return last.version.check
        }
        if case .checked(let result)? = explanation?.draft {
            return result
        }
        return nil
    }

    /// The newest draft the model made, nil when there is none.
    var modelDraft: String? {
        draftCheck?.draft
    }

    /// Whether the user changed the draft in the editor since the model made it.
    var isEdited: Bool {
        modelDraft.map { $0 != text } ?? false
    }

    /// Whether there is a draft to change, check and hand off.
    var hasDraft: Bool {
        modelDraft != nil
    }

    /// Whether a request runs on the draft, so the editor and the buttons wait.
    var isBusy: Bool {
        changing != nil || isUndoing
    }

    /// Whether a handoff of this window runs, so Open Reply in Mail, Reply All and Copy wait.
    var isHandingOff: Bool {
        handoffs.isRunning
    }

    /// The flags of the newest draft the model made that still hold for the text in the
    /// editor: a date or amount it still holds, and the flag for a question it may decide.
    var flags: [DraftCheck.Flag] {
        let digits = NumberRules.writingNumbersAsDigits(in: text)
        return (draftCheck?.flags ?? []).filter { flag in
            guard case .output(let finding) = flag else { return true }
            return text.contains(finding.text) || digits.contains(finding.text)
        }
    }

    /// The people outside the project whom a reply to all reaches, lowercased.
    var outsideRecipients: [String] {
        draftCheck?.outsideRecipients ?? []
    }

    /// Whether a reply to all reaches more people than the sender.
    var offersReplyAll: Bool {
        (explanation?.draftCheck?.recipients.count ?? 0) > 1
    }

    /// The language Show in My Language translates into: the one the user reads
    /// explanations in, Chinese or English (decision 8).
    var translationLanguage: ProjectsLanguage {
        actions.userLanguage == .zh ? .zh : .en
    }

    /// Whether the draft's language differs from the user's, so Show in My Language helps.
    var offersTranslation: Bool {
        guard let language = explanation?.reply.draftLanguage else { return false }
        return language != translationLanguage
    }

    /// The newest version with what it changed, worked out off the main actor.
    private func change(of versions: [MailStore.DraftVersion]) async -> LastChange? {
        guard let last = versions.last, let after = last.version.draft else { return nil }
        var before = madeFrom[last.number]
        if before == nil, versions.count > 1 {
            before = versions[versions.count - 2].version.draft
        }
        if before == nil, case .checked(let result)? = explanation?.draft {
            before = result.draft
        }
        return LastChange(version: last, segments: await ProjectsDraftDiff.highlight(from: before ?? "", to: after))
    }

    /// Takes the versions as they are now, with the highlight of the newest. Nothing changes
    /// when they are as before, so selecting the email again works out nothing.
    private func take(_ versions: [MailStore.DraftVersion]) async {
        guard versions != self.versions || (lastChange == nil && !versions.isEmpty) else { return }
        let change = await change(of: versions)
        self.versions = versions
        lastChange = change
    }

    /// The translation for the text in the editor, nil while there is none for it.
    var currentTranslation: Translation? {
        translation?.draft == text ? translation : nil
    }

    /// The answer check for the text in the editor, nil while there is none for it.
    var currentAnswers: ReviseService.Answers? {
        answers?.draft == text ? answers?.answers : nil
    }

    // MARK: Loading

    /// Reads the explanation and the versions of the draft. The editor's text stays when
    /// both are as before, so the user's edits stay.
    func load() async {
        let explanation = await actions.explanation(messageID)
        let versions = explanation == nil ? [] : await actions.versions(messageID)
        let changed = !isLoaded || explanation != self.explanation || versions != self.versions
        if explanation != self.explanation {
            madeFrom = [:]
        }
        madeFrom = madeFrom.filter { number, _ in versions.contains { $0.number == number } }
        if explanation != self.explanation {
            self.explanation = explanation
        }
        await take(versions)
        isLoaded = true
        if changed {
            text = modelDraft ?? ""
            changeNote = nil
            translationNote = nil
            answersNote = nil
            handoffNote = nil
        }
        await readSources()
    }

    /// Reads what the source ids stand for, and the email's own text.
    private func readSources() async {
        guard let explanation else {
            sources = [:]
            emailText = ""
            return
        }
        var sources: [String: Source] = [:]
        for (id, source) in explanation.sources {
            switch source {
            case .message(let messageID) where messageID == explanation.messageID:
                sources[id] = .thisEmail
            case .message(let messageID):
                let email = await actions.email(messageID)
                let sender = email.map { $0.sender.name.isEmpty ? $0.sender.address : $0.sender.name }
                sources[id] = .mail(messageID: messageID, sender: sender, date: email?.date)
            case .file(let chunk):
                sources[id] = .file(chunk)
            }
        }
        self.sources = sources
        emailText = await actions.email(messageID).map { $0.text.isEmpty ? $0.visibleText : $0.text } ?? ""
    }

    /// After a new explanation in this window: reads it, and runs the answer check of its
    /// draft once (decision 9).
    func explained() async {
        await load()
        guard !isEdited else { return }
        await checkAnswers()
    }

    // MARK: Requests

    /// Runs a request of the user on this email, such as a change, a translation or the
    /// answer check, in a task kept until it ends, so `cancelWork()` can end it.
    func perform(_ request: @escaping @MainActor (ProjectsEmailModel) async -> Void) {
        let id = UUID()
        work[id] = Task { [weak self] in
            guard let self else { return }
            await request(self)
            self.work[id] = nil
        }
    }

    /// Ends the requests on this email, such as when the window closes or a project is
    /// forgotten. Each ends at its next slice of the model and saves nothing.
    func cancelWork() {
        let running = work.values
        work = [:]
        for task in running {
            task.cancel()
        }
    }

    /// Whether a request started with `perform(_:)` runs, for tests.
    var isWorking: Bool {
        !work.isEmpty
    }

    /// Runs one request of the model as the user's, see Actions.userRequest.
    private func userRequest<T>(_ request: @escaping @MainActor () async throws -> T) async throws -> T {
        let result = RequestResult<T>()
        try await actions.userRequest { result.value = try await request() }
        guard let value = result.value else { throw CancellationError() }
        return value
    }

    /// What a request of the model gave, handed out of `userRequest(_:)`.
    private final class RequestResult<T> {
        var value: T?
    }

    // MARK: Changes

    /// Puts the words of a dictation into the change box, after what it holds, and with
    /// `revises` changes the draft with them at once, as a click on Change Draft would. While
    /// a change or an undo runs, the draft changes with what the box holds once that ends,
    /// unless it gave no new draft. Returns false and takes nothing when there is no draft
    /// to change or nothing to put in.
    ///
    /// The words reach the box inside Orra, with no clipboard and no Command V. The change
    /// waits in ProjectsModelQueue until the dictation has ended, so it never holds up the
    /// paste of the dictation itself.
    func takeDictation(_ words: String, revises: Bool) -> Bool {
        guard hasDraft, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        instruction = RecordingPieces.joined([instruction, words])
        if revises {
            if isBusy {
                changesWhenFree = true
            } else {
                perform { await $0.applyInstruction() }
            }
        }
        return true
    }

    /// Applies the instruction of the change box, and returns whether it made a new version.
    @discardableResult
    func applyInstruction() async -> Bool {
        let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        return await makeChange(.instruction(words))
    }

    /// Makes a new version of the draft in the editor, from an instruction or in a tone,
    /// keeps it when the store saved it, and returns whether it made one.
    @discardableResult
    func makeChange(_ change: RevisePrompt.Change) async -> Bool {
        guard changing == nil, !isUndoing, let explanation, hasDraft else { return false }
        let before = text
        changing = change
        changeNote = nil
        handoffNote = nil
        let made: Bool
        do {
            made = try await makeVersion(change, from: before, explanation: explanation)
        } catch is CancellationError {
            made = false
        } catch {
            changeNote = Self.note(error)
            made = false
        }
        changing = nil
        let changesAgain = changesWhenFree
        changesWhenFree = false
        guard made else { return false }
        if case .instruction(let words) = change {
            instruction = Self.remainder(of: instruction, after: words)
        }
        // The talk key's words that came meanwhile change the draft next, see
        // takeDictation(_:revises:). The checks then run once, for the newest version.
        if changesAgain, await applyInstruction() {
            return true
        }
        await afterNewVersion()
        return true
    }

    /// What stays in the change box after a change made from `words`: what the user typed
    /// or said after them while the change ran, or all of it when the user changed those
    /// words meanwhile.
    nonisolated static func remainder(of box: String, after words: String) -> String {
        let held = box.drop { $0.isWhitespace || $0.isNewline }
        guard held.hasPrefix(words) else { return box }
        return String(held.dropFirst(words.count).drop { $0.isWhitespace || $0.isNewline })
    }

    private func makeVersion(_ change: RevisePrompt.Change, from before: String, explanation: Explanation) async throws -> Bool {
        guard let context = await actions.reviseContext(explanation) else {
            changeNote = .other
            return false
        }
        let flags = draftCheck?.flags ?? []
        let version = try await userRequest { [actions] in
            let service = try await actions.reviseService(actions.now())
            return try await service.revise(before, change, flags: flags, context: context)
        }
        guard let draft = version.draft else {
            changeNote = .heldBack
            return false
        }
        let saved = await actions.versions(messageID)
        guard let last = saved.last, last.version == version, !versions.contains(where: { $0.number == last.number }) else {
            changeNote = .notKept
            await load()
            return false
        }
        madeFrom[last.number] = before
        await take(saved)
        text = draft
        return true
    }

    /// Undo of the newest change: removes the newest version and puts back the text it was
    /// made from. It stays busy until the versions, the highlight and the text are all in
    /// place, so neither the editor nor another request works on the version it removes.
    /// The talk key's words that came meanwhile then change the draft, see
    /// `takeDictation(_:revises:)`.
    func undo() async {
        guard let last = versions.last, !isBusy else { return }
        isUndoing = true
        changeNote = nil
        handoffNote = nil
        let removed = await actions.removeNewestVersion(messageID)
        let saved = await actions.versions(messageID)
        let undone = removed && !saved.contains { $0.number == last.number }
        if undone {
            let before = madeFrom.removeValue(forKey: last.number)
            await take(saved)
            text = before ?? modelDraft ?? ""
        } else {
            await load()
        }
        isUndoing = false
        let changesAgain = changesWhenFree
        changesWhenFree = false
        if undone, changesAgain {
            await applyInstruction()
        }
    }

    /// After a new version: the answer check, and the translation while it shows.
    private func afterNewVersion() async {
        if showsTranslation {
            await translate()
        }
        await checkAnswers()
    }

    // MARK: Translation and answers

    /// Turns Show in My Language on or off, and translates the draft when it is on and
    /// has no translation yet.
    func showTranslation(_ shows: Bool) async {
        showsTranslation = shows
        if shows, currentTranslation == nil {
            await translate()
        }
    }

    /// Translates the draft in the editor into the user's language, unless it was translated
    /// as it is. Asked while a translation runs, it translates again once that one ends, for
    /// the text then.
    func translate() async {
        guard hasDraft else { return }
        guard !isTranslating else {
            translateAgain = true
            return
        }
        isTranslating = true
        defer { isTranslating = false }
        repeat {
            translateAgain = false
            guard let explanation, hasDraft, translation?.draft != text else { return }
            let draft = text
            translationNote = nil
            do {
                guard let context = await actions.reviseContext(explanation) else { throw Note.other }
                let translated = try await userRequest { [actions] in
                    let service = try await actions.reviseService(actions.now())
                    return try await service.translate(draft, context: context)
                }
                translation = Translation(draft: draft, text: translated ?? draft)
            } catch is CancellationError {
                return
            } catch {
                translationNote = Self.note(error)
            }
        } while translateAgain
    }

    /// Which of the email's questions the draft in the editor answers, unless that was
    /// checked as it is. Asked while a check runs, it checks again once that one ends, for
    /// the text then.
    func checkAnswers() async {
        guard hasDraft else { return }
        guard !isCheckingAnswers else {
            checkAgain = true
            return
        }
        isCheckingAnswers = true
        defer { isCheckingAnswers = false }
        repeat {
            checkAgain = false
            guard let explanation, hasDraft, answers?.draft != text else { return }
            let draft = text
            answersNote = nil
            do {
                guard let context = await actions.reviseContext(explanation) else { throw Note.other }
                let checked = try await userRequest { [actions] in
                    let service = try await actions.reviseService(actions.now())
                    return try await service.checkAnswers(of: draft, context: context)
                }
                answers = Answers(draft: draft, answers: checked)
            } catch is CancellationError {
                return
            } catch {
                answersNote = Self.note(error)
            }
        } while checkAgain
    }

    // MARK: Handoff

    /// Open Reply in Mail, or Reply All with `all`, with the draft in the editor. Nothing
    /// happens while a handoff of the window runs. Mail first confirms that its message is
    /// this email, and when it is not, or Mail cannot say, the draft is only copied.
    func openReply(all: Bool) async {
        guard !handoffs.isRunning else { return }
        handoffs.isRunning = true
        handoffNote = nil
        defer { handoffs.isRunning = false }
        let reference: MailMessageRef?
        do {
            reference = try await actions.mailReference(messageID, all)
        } catch is CancellationError {
            // The window closed before Mail answered, so the clipboard stays as it is.
            return
        } catch {
            var error = error as? MailBridgeError ?? .failed(code: (error as NSError).code)
            // Mail was not asked to reply, so the note must not say that the reply may still
            // open.
            if error == .timedOut { error = .failed(code: -1712) }
            let copied = actions.handoff.copyOnly(text)
            guard copied == .copied else {
                handoffNote = .outcome(copied)
                return
            }
            handoffNote = .outcome(error == .mailNotRunning ? .copiedMailNotRunning : .copiedReplyFailed(error))
            return
        }
        guard !Task.isCancelled else { return }
        guard let reference else {
            // Mail's handles go when it quits, so say that Mail is not open rather than that
            // the email was not found.
            guard actions.handoff.mail.isRunning() else {
                let copied = actions.handoff.copyOnly(text)
                handoffNote = .outcome(copied == .copied ? .copiedMailNotRunning : copied)
                return
            }
            let copied = actions.handoff.copyOnly(text)
            handoffNote = copied == .copied ? .messageNotFound : .outcome(copied)
            return
        }
        handoffNote = .outcome(await actions.handoff.openReply(text, to: reference, all: all))
    }

    /// Copy: puts the draft in the editor on the clipboard, unless a handoff of the window
    /// runs.
    func copy() {
        guard !handoffs.isRunning else { return }
        handoffNote = .outcome(actions.handoff.copyOnly(text))
    }

    // MARK: Helpers

    /// The note for an error of ReviseService or of the runtime.
    nonisolated static func note(_ error: any Error) -> Note {
        if let note = error as? Note {
            return note
        }
        switch error {
        case RewriteError.notLoaded, ProjectsRuntime.Failure.windowClosed, ProjectsRuntime.Failure.off:
            return .noModel
        case RewriteError.promptTooLong, ReviseService.Failure.tooLong:
            return .tooLong
        case ReviseService.Failure.emptyAnswer, ReviseService.Failure.cutShort, ReviseService.Failure.unreadableAnswer, ReviseService.Failure.wrongLanguage:
            return .noAnswer
        case ReviseService.Failure.emptyDraft, ReviseService.Failure.emptyInstruction:
            return .emptyDraft
        default:
            return .other
        }
    }
}

extension ProjectsEmailModel.Note: Error {}

// MARK: The deadline

extension ProjectsEmailModel {
    /// The deadline mark of an explained email: the earliest date its points name as a
    /// deadline, from today on. A date counts when a word of a deadline stands right before
    /// or after it, such as "by", "due", "before", 截止, 最晚, or 前 after the date, as in
    /// 10月24日（周五）前. A date without a year takes the year that puts it closest to the
    /// day of the explanation. Nil when no point names one. The words are a guess.
    nonisolated static func deadline(of explanation: Explanation, now: Date, calendar: Calendar = .current) -> Date? {
        deadline(in: explanation.points.map(\.text), explainedOn: explanation.today, now: now, calendar: calendar)
    }

    nonisolated static func deadline(in texts: [String], explainedOn explained: Date, now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        var found: Date?
        for text in texts {
            for mention in OutputChecks.dates(in: text) where isDeadline(mention, in: text) {
                guard let date = resolved(mention, near: explained, calendar: calendar), date >= today else { continue }
                found = min(found ?? date, date)
            }
        }
        return found
    }

    private nonisolated static func isDeadline(_ mention: OutputChecks.DateMention, in text: String) -> Bool {
        let before = String(text[..<mention.range.lowerBound].suffix(32))
        let after = String(text[mention.range.upperBound...].prefix(16))
        return cueBefore.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil
            || cueAfter.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil
    }

    /// A deadline word right before the date, with a weekday between them at most, as in
    /// "by Friday, 23 October", "due on 23 Oct", 截止日期为 and 请在.
    private nonisolated static let cueBefore = try! NSRegularExpression(
        pattern: #"(?:\b(?:by|before|until|till|due(?:\s+(?:on|by))?|deadline(?:\s+(?:is|of))?|no\s+later\s+than)\b[\s,:]*(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s*)?(?:the\s+)?|(?:截止|截至|最晚|最迟|期限|到期|请于|须于|需于|请在|须在|需在|要在|务必在)(?:日期|时间)?[为是]?[：:\s]*(?:(?:周|星期)[一二三四五六日天][，,\s]*)?)$"#,
        options: .caseInsensitive
    )

    /// A deadline word right after the date, after a weekday in brackets at most, as in
    /// 10月24日（周五）前, 10月24日截止 and "23 October at the latest".
    private nonisolated static let cueAfter = try! NSRegularExpression(
        pattern: #"^\s*(?:[（(][^）)]{0,12}[）)])?\s*(?:之前|以前|前(?!后)|截止|到期|为止|\bat\s+the\s+latest\b|\bdeadline\b)"#,
        options: .caseInsensitive
    )

    /// The day of a date, in the year the mention names or the one closest to `near`.
    private nonisolated static func resolved(_ mention: OutputChecks.DateMention, near: Date, calendar: Calendar) -> Date? {
        let thisYear = calendar.component(.year, from: near)
        let years = mention.year.map { [$0] } ?? [thisYear - 1, thisYear, thisYear + 1]
        let candidates = years.compactMap { year -> Date? in
            let wanted = DateComponents(year: year, month: mention.month, day: mention.day)
            guard let date = calendar.date(from: wanted),
                  calendar.dateComponents([.year, .month, .day], from: date) == wanted else { return nil }
            return date
        }
        return candidates.min { abs($0.timeIntervalSince(near)) < abs($1.timeIntervalSince(near)) }
    }
}
