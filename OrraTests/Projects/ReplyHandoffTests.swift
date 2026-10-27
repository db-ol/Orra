import Foundation
import Synchronization
import Testing
@testable import Orra

/// The reply handoff with a fake clipboard, a fake Mail behind the real MailBridge, and fakes
/// of whether Orra is in front and of the activation, which record what happened in order.
/// No test touches a pasteboard, sends an Apple Event or brings an app to the front.
@MainActor
struct ReplyHandoffTests {
    private typealias Request = MailEvents.Request

    private static let mailbox = MailMailbox(
        kind: .mailbox,
        reference: .name(MailEvents.Code.mailbox, "Harbor", of: .application),
        name: "Harbor",
        account: nil
    )
    private static let message = MailMessageRef(id: 4217, mailbox: mailbox)
    private static let draft = "Dear Mei,\n\nThe samples ship on Friday, 23 October.\n\nBest,\nLin\n"
    fileprivate nonisolated static let session = MailEvents.Session(processIdentifier: 811, launched: Date(timeIntervalSince1970: 1_761_400_000))
    fileprivate nonisolated static let laterSession = MailEvents.Session(processIdentifier: 942, launched: Date(timeIntervalSince1970: 1_761_403_600))
    private static let folder = URL(fileURLWithPath: "/Users/someone/Projects/Harbor lobby/Drawings", isDirectory: true)
    private static let plan = folder.appending(path: "floor-plan-v3.pdf")
    private static let quote = folder.appending(path: "quote-2026.xlsx")
    private static let sketch = folder.appending(path: "平面图草图.png")

    private static func attach(_ file: URL) -> Fixture.Step {
        .send(.attach(file, toReply: 77, in: session))
    }

    /// A ticked file as the handoff takes it, with an identity of its own.
    private static func ticked(_ url: URL) -> ReplyFile {
        ReplyFile(url: url, projects: [], identity: ReplyFile.Identity(
            device: 16_777_231, fileSystem: 26, number: 7,
            made: Date(timeIntervalSince1970: 1_760_000_000), size: 1_000, modified: Date(timeIntervalSince1970: 1_761_000_000)))
    }

    /// The ticked files, each of which passes its check as it is.
    private static func files(_ urls: [URL]) -> ReplyHandoff.Files {
        ReplyHandoff.Files(urls.map(ticked)) { .success($0) }
    }

    @Test(arguments: [false, true])
    func openReplyCopiesRepliesCopiesAgainThenBringsMailToTheFront(all: Bool) async {
        let fixture = Fixture()
        let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: all)
        #expect(outcome == .replyOpened(files: []))
        #expect(fixture.steps == [
            .copy(Self.draft),
            .send(.reply(to: Self.message.reference, all: all)),
            .copy(Self.draft),
            .front,
        ])
    }

    /// The user went to another app while Mail made the reply. A copy made there stays, and
    /// Mail does not come over that app.
    @Test func afterTheUserLeftOrraTheReplyOpensWithoutCopyOrFront() async {
        let fixture = Fixture()
        fixture.leavesOrraOnReply = true
        #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: false) == .replyOpened(files: []))
        #expect(fixture.steps == [.copy(Self.draft), .send(.reply(to: Self.message.reference, all: false))])
        #expect(fixture.activeChecks == 1)
    }

    @Test func theDraftIsCopiedAsItIs() async {
        let fixture = Fixture()
        let draft = "  王经理您好：\n\n样品周五发出。\n\n"
        #expect(await fixture.handoff().openReply(draft, to: Self.message, all: false) == .replyOpened(files: []))
        #expect(fixture.steps.first == .copy(draft))
        #expect(fixture.steps.dropFirst(2).first == .copy(draft))
    }

    @Test func withMailNotRunningItOnlyCopies() async {
        let fixture = Fixture()
        fixture.mailRunning = false
        #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: false) == .copiedMailNotRunning)
        #expect(fixture.steps == [.copy(Self.draft)])
    }

    @Test func mailQuittingBeforeItAnswersCountsAsNotRunning() async {
        let fixture = Fixture()
        fixture.replyFailure = -600
        fixture.quitsOnReply = true
        #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: true) == .copiedMailNotRunning)
        #expect(fixture.steps == [.copy(Self.draft), .send(.reply(to: Self.message.reference, all: true))])
    }

    @Test func aFailedReplyKeepsTheDraftCopiedAndLeavesMailWhereItIs() async {
        let cases: [(code: Int, error: MailBridgeError)] = [
            (-1743, .denied),
            (-1744, .notAsked),
            (-1712, .timedOut),
            (-1728, .notFound),
            (-600, .notAnswered(code: -600)),
            (-10000, .failed(code: -10000)),
        ]
        for item in cases {
            let fixture = Fixture()
            fixture.replyFailure = item.code
            #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: false) == .copiedReplyFailed(item.error))
            #expect(fixture.steps == [.copy(Self.draft), .send(.reply(to: Self.message.reference, all: false))])
        }
    }

    /// The reply waits on a real send thread behind an earlier event, and the window goes
    /// away before its turn. The thread never runs it, and the handoff only copied. A
    /// handoff that hung would hang the test, and the time limit stops it.
    @Test(.timeLimit(.minutes(1)))
    func aReplyCancelledBeforeItsTurnOnlyCopies() async throws {
        let thread = MailEvents.SendThread()
        let (started, starting) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let earlier = Task {
            try await thread.run {
                starting.yield()
                release.wait()
            }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()

        let fixture = Fixture(sendThread: thread)
        let handoff = fixture.handoff()
        let reply = Task { await handoff.openReply(Self.draft, to: Self.message, all: false) }
        while fixture.steps.isEmpty {
            await Task.yield()
        }
        reply.cancel()
        #expect(await reply.value == .copied)

        release.signal()
        try await earlier.value
        // The thread runs its work in order, so the reply would have run before this.
        try await thread.run {}
        #expect(fixture.steps == [.copy(Self.draft)])
        #expect(fixture.activeChecks == 0)
    }

    /// The window goes away while the reply's event is on its way to Mail, which nothing
    /// can call back. Mail opens the reply window, but the draft is not copied again and
    /// Mail does not come to the front. A handoff that hung would hang the test, and the
    /// time limit stops it.
    @Test(.timeLimit(.minutes(1)))
    func aReplyCancelledWhileMailMakesItLeavesTheClipboardAndMail() async {
        let gate = DispatchSemaphore(value: 0)
        let fixture = Fixture(sendThread: MailEvents.SendThread(), gate: gate)
        let handoff = fixture.handoff()
        let reply = Task { await handoff.openReply(Self.draft, to: Self.message, all: false) }
        // Once Mail is asked, the send thread holds the reply and a cancel cannot take it back.
        while !fixture.steps.contains(.send(.reply(to: Self.message.reference, all: false))) {
            await Task.yield()
        }
        reply.cancel()
        gate.signal()
        #expect(await reply.value == .replyOpened(files: []))
        #expect(fixture.steps == [.copy(Self.draft), .send(.reply(to: Self.message.reference, all: false))])
        #expect(fixture.activeChecks == 0)
    }

    @Test func copyOnlyAsksNothingOfMail() {
        let fixture = Fixture()
        #expect(fixture.handoff().copyOnly(Self.draft) == .copied)
        #expect(fixture.steps == [.copy(Self.draft)])
        #expect(fixture.runningChecks == 0)
        #expect(fixture.activeChecks == 0)
    }

    @Test func anEmptyDraftChangesNothing() async {
        for draft in ["", " \n\t", "\u{3000}\n"] {
            let fixture = Fixture()
            #expect(await fixture.handoff().openReply(draft, to: Self.message, all: false) == .emptyDraft)
            #expect(fixture.handoff().copyOnly(draft) == .emptyDraft)
            #expect(fixture.steps.isEmpty)
            #expect(fixture.runningChecks == 0)
        }
    }

    @Test func aDraftThePasteboardRefusesOpensNoReply() async {
        let fixture = Fixture()
        fixture.copyWorks = false
        #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: Self.files([Self.plan])) == .notCopied)
        #expect(fixture.handoff().copyOnly(Self.draft) == .notCopied)
        #expect(fixture.steps == [.copy(Self.draft), .copy(Self.draft)])
        #expect(fixture.runningChecks == 0)
    }

    // MARK: Files

    /// Each file goes in its own event, in order, after the reply and before the draft goes
    /// on the clipboard again.
    @Test(arguments: [false, true])
    func openReplyAttachesEachFileBetweenTheReplyAndTheSecondCopy(all: Bool) async {
        let fixture = Fixture()
        let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: all, files: Self.files([Self.plan, Self.sketch]))
        #expect(outcome == .replyOpened(files: [.attached, .attached]))
        #expect(fixture.steps == [
            .copy(Self.draft),
            .send(.reply(to: Self.message.reference, all: all)),
            Self.attach(Self.plan),
            Self.attach(Self.sketch),
            .copy(Self.draft),
            .front,
        ])
    }

    @Test func aFileMailRefusesIsSkippedAndTheNextIsAttached() async {
        for code in [-10000, -1700, -43] {
            let fixture = Fixture()
            fixture.attachFailures = [Self.plan: code]
            let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: Self.files([Self.plan, Self.quote]))
            #expect(outcome == .replyOpened(files: [.notAttached(.refused(code: code)), .attached]))
            #expect(fixture.steps.suffix(4) == [Self.attach(Self.plan), Self.attach(Self.quote), .copy(Self.draft), .front])
        }
    }

    /// A closed reply window, a refused permission and Mail quitting stop the files after it
    /// with the same reason, and Mail is not asked for them.
    @Test func aClosedReplyWindowAPermissionOrMailQuittingStopsTheRest() async {
        let cases: [(code: Int, quits: Bool, problem: ReplyHandoff.AttachProblem)] = [
            (-1728, false, .replyClosed),
            (-1743, false, .notAllowed),
            (-1744, false, .notAllowed),
            (-600, true, .mailQuit),
            (-609, true, .mailQuit),
        ]
        for item in cases {
            let fixture = Fixture()
            fixture.attachFailures = [Self.quote: item.code]
            fixture.quitsOnAttach = item.quits ? Self.quote : nil
            let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: Self.files([Self.plan, Self.quote, Self.sketch]))
            #expect(outcome == .replyOpened(files: [.attached, .notAttached(item.problem), .notAttached(item.problem)]))
            #expect(fixture.steps.filter(\.isAttach) == [Self.attach(Self.plan), Self.attach(Self.quote)])
        }
    }

    /// After a timeout no further file is asked for, since a slow Mail would hold the send
    /// thread up to the timeout for each of them. The file that timed out may still arrive.
    @Test func aTimeOutStopsTheRest() async {
        let fixture = Fixture()
        fixture.attachFailures = [Self.plan: -1712]
        let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: Self.files([Self.plan, Self.quote, Self.sketch]))
        #expect(outcome == .replyOpened(files: [.notAttached(.timedOut), .notAttached(.afterTimeOut), .notAttached(.afterTimeOut)]))
        #expect(fixture.steps.filter(\.isAttach) == [Self.attach(Self.plan)])
        #expect(fixture.steps.suffix(2) == [.copy(Self.draft), .front])
    }

    /// Mail quit after the first file and another Mail started, which may give the reply's
    /// id to another message. No further file goes, and they say that Mail quit.
    @Test func mailStartingAgainStopsTheRest() async {
        let fixture = Fixture()
        fixture.restartsOnAttach = Self.plan
        let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: Self.files([Self.plan, Self.quote, Self.sketch]))
        #expect(outcome == .replyOpened(files: [.attached, .notAttached(.mailQuit), .notAttached(.mailQuit)]))
        #expect(fixture.steps.filter(\.isAttach) == [Self.attach(Self.plan)])
    }

    /// Mail made the reply but its answer named no outgoing message, or another Mail made
    /// it, so Orra cannot tell where the files would go and sends none.
    @Test func aReplyMailDoesNotNameGetsNoAttachments() async {
        let answers: [MailEvents.Value] = [.missing, .reference(.id(MailEvents.Code.message, 77, of: .application))]
        for answer in answers {
            let fixture = Fixture()
            fixture.replyAnswer = answer
            let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: Self.files([Self.plan, Self.quote]))
            #expect(outcome == .replyOpened(files: [.notAttached(.noReplyNamed), .notAttached(.noReplyNamed)]))
            #expect(fixture.steps == [.copy(Self.draft), .send(.reply(to: Self.message.reference, all: false)), .copy(Self.draft), .front])
        }
        let restarted = Fixture()
        restarted.restartsOnReply = true
        let outcome = await restarted.handoff().openReply(Self.draft, to: Self.message, all: false, files: Self.files([Self.plan]))
        #expect(outcome == .replyOpened(files: [.notAttached(.noReplyNamed)]))
        #expect(restarted.steps.filter(\.isAttach).isEmpty)
    }

    /// Each file is checked again right before its event, in order, and the event takes the
    /// file as the check gives it, at its new place after a rename. A file that fails its
    /// check is not asked for, and the next one still goes.
    @Test func eachFileIsCheckedRightBeforeItsEvent() async {
        let fixture = Fixture()
        let (plan, quote) = (Self.plan, Self.quote)
        let renamed = Self.folder.appending(path: "floor-plan-v3-final.pdf")
        // Each file checked, with how many files Mail was asked for before its check.
        let checks = Mutex<[(URL, Int)]>([])
        let files = ReplyHandoff.Files([Self.plan, Self.quote, Self.sketch].map(Self.ticked)) { file in
            let asked = fixture.steps.filter(\.isAttach).count
            checks.withLock { $0.append((file.url, asked)) }
            switch file.url {
            case plan:
                var moved = file
                moved.url = renamed
                return .success(moved)
            case quote:
                return .failure(.changed)
            default:
                return .success(file)
            }
        }
        let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: files)
        #expect(outcome == .replyOpened(files: [.attached, .notAttached(.notChecked(.changed)), .attached]))
        #expect(checks.withLock { $0.map(\.0) } == [Self.plan, Self.quote, Self.sketch])
        #expect(checks.withLock { $0.map(\.1) } == [0, 1, 1])
        #expect(fixture.steps == [
            .copy(Self.draft),
            .send(.reply(to: Self.message.reference, all: false)),
            Self.attach(renamed),
            Self.attach(Self.sketch),
            .copy(Self.draft),
            .front,
        ])
    }

    /// No file is checked when Mail named no reply or a stop came first, since none goes.
    @Test func noCheckRunsForAFileThatCannotGo() async {
        let fixture = Fixture()
        fixture.replyAnswer = .missing
        let checked = Mutex(0)
        let files = ReplyHandoff.Files([Self.plan, Self.quote].map(Self.ticked)) { file in
            checked.withLock { $0 += 1 }
            return .success(file)
        }
        #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: files) == .replyOpened(files: [.notAttached(.noReplyNamed), .notAttached(.noReplyNamed)]))
        #expect(checked.withLock { $0 } == 0)

        let closed = Fixture()
        closed.attachFailures = [Self.plan: -1728]
        #expect(await closed.handoff().openReply(Self.draft, to: Self.message, all: false, files: files) == .replyOpened(files: [.notAttached(.replyClosed), .notAttached(.replyClosed)]))
        #expect(checked.withLock { $0 } == 1)
    }

    /// The window goes away while Mail adds the first file, which nothing can call back.
    /// Mail is not asked for the files after it, the outcome leaves them out, the draft is
    /// not copied again and Mail does not come to the front.
    @Test(.timeLimit(.minutes(1)))
    func closingTheWindowWhileAttachingSendsNoMore() async {
        let gate = DispatchSemaphore(value: 0)
        let fixture = Fixture(sendThread: MailEvents.SendThread(), attachGate: gate)
        let handoff = fixture.handoff()
        let reply = Task { await handoff.openReply(Self.draft, to: Self.message, all: false, files: Self.files([Self.plan, Self.quote, Self.sketch])) }
        while !fixture.steps.contains(Self.attach(Self.plan)) {
            await Task.yield()
        }
        reply.cancel()
        gate.signal()
        #expect(await reply.value == .replyOpened(files: [.attached]))
        #expect(fixture.steps == [.copy(Self.draft), .send(.reply(to: Self.message.reference, all: false)), Self.attach(Self.plan)])
        #expect(fixture.activeChecks == 0)
    }

    /// An email Projects wrote no draft for: the reply and its files, and Mail to the front,
    /// but nothing on the clipboard.
    @Test func withoutADraftNothingIsCopied() async {
        let fixture = Fixture()
        let outcome = await fixture.handoff().openReply(nil, to: Self.message, all: true, files: Self.files([Self.plan]))
        #expect(outcome == .replyOpened(files: [.attached]))
        #expect(fixture.steps == [.send(.reply(to: Self.message.reference, all: true)), Self.attach(Self.plan), .front])
    }

    /// Without a draft, no failure puts anything on the clipboard either: Mail not running,
    /// Mail quitting or failing to make the reply, and a handoff cancelled before Mail was
    /// asked.
    @Test(.timeLimit(.minutes(1)))
    func withoutADraftNoFailureTouchesTheClipboard() async throws {
        let notRunning = Fixture()
        notRunning.mailRunning = false
        #expect(await notRunning.handoff().openReply(nil, to: Self.message, all: false, files: Self.files([Self.plan])) == .mailNotRunning)
        #expect(notRunning.steps.isEmpty)

        let quitting = Fixture()
        quitting.replyFailure = -600
        quitting.quitsOnReply = true
        #expect(await quitting.handoff().openReply(nil, to: Self.message, all: false, files: Self.files([Self.plan])) == .mailNotRunning)
        #expect(quitting.steps == [.send(.reply(to: Self.message.reference, all: false))])

        for (code, error) in [(-1743, MailBridgeError.denied), (-1712, .timedOut), (-1728, .notFound), (-10000, .failed(code: -10000))] {
            let failing = Fixture()
            failing.replyFailure = code
            #expect(await failing.handoff().openReply(nil, to: Self.message, all: false, files: Self.files([Self.plan])) == .replyFailed(error))
            #expect(failing.steps == [.send(.reply(to: Self.message.reference, all: false))])
        }

        // Cancelled while an earlier event holds the send thread, so Mail is never asked.
        let thread = MailEvents.SendThread()
        let (started, starting) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let earlier = Task {
            try await thread.run {
                starting.yield()
                release.wait()
            }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        let cancelled = Fixture(sendThread: thread)
        let handoff = cancelled.handoff()
        let reply = Task { await handoff.openReply(nil, to: Self.message, all: false, files: Self.files([Self.plan])) }
        while cancelled.runningChecks == 0 {
            await Task.yield()
        }
        reply.cancel()
        #expect(await reply.value == .stopped)
        release.signal()
        try await earlier.value
        try await thread.run {}
        #expect(cancelled.steps.isEmpty)
    }

    /// When Mail could not confirm the email, the window asks no reply: the draft goes on
    /// the clipboard as Copy puts it, and without a draft nothing does.
    @Test func replyNotAskedCopiesOnlyWithADraft() {
        let errors: [MailBridgeError] = [.mailNotRunning, .denied, .notFound, .failed(code: -1712)]
        for error in errors {
            let withDraft = Fixture()
            let copied = withDraft.handoff().replyNotAsked(Self.draft, because: error)
            #expect(copied == (error == .mailNotRunning ? .copiedMailNotRunning : .copiedReplyFailed(error)))
            #expect(withDraft.steps == [.copy(Self.draft)])

            let withoutDraft = Fixture()
            let outcome = withoutDraft.handoff().replyNotAsked(nil, because: error)
            #expect(outcome == (error == .mailNotRunning ? .mailNotRunning : .replyFailed(error)))
            #expect(withoutDraft.steps.isEmpty)
            #expect(withoutDraft.runningChecks == 0)
        }
        let refusing = Fixture()
        refusing.copyWorks = false
        #expect(refusing.handoff().replyNotAsked(Self.draft, because: .denied) == .notCopied)
        #expect(refusing.handoff().replyNotAsked(" \n", because: .denied) == .emptyDraft)
    }

    /// The log line of a handoff shows the outcome, which holds error codes only, never a
    /// file's name or its path.
    @Test func theOutcomeHoldsNoNameOrPath() async {
        let fixture = Fixture()
        fixture.attachFailures = [Self.quote: -10000, Self.sketch: -1728]
        let plan = Self.plan
        let files = ReplyHandoff.Files([Self.plan, Self.quote, Self.sketch].map(Self.ticked)) { file in
            file.url == plan ? .failure(.notInAddedFolder) : .success(file)
        }
        let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: false, files: files)
        let logged = String(describing: outcome)
        #expect(logged.contains("refused"))
        #expect(logged.contains("notInAddedFolder"))
        for word in ["floor-plan", "quote-2026", "平面图", "Harbor", "Drawings", "/Users", "someone", ".pdf"] {
            #expect(!logged.contains(word))
        }
    }

    /// The clipboard, Mail, whether Orra is in front and the activation, as a test sets them,
    /// with what each was asked. With a send thread, Mail's events wait their turn on it.
    /// With a gate, Mail answers an event only once the test signals it.
    private final class Fixture: Sendable {
        enum Step: Equatable, Sendable {
            case copy(String)
            case send(Request)
            case front

            var isAttach: Bool {
                guard case .send(.attach) = self else { return false }
                return true
            }
        }

        private struct State {
            var steps: [Step] = []
            var runningChecks = 0
            var mailRunning = true
            var copyWorks = true
            var replyFailure: Int?
            var quitsOnReply = false
            var orraActive = true
            var activeChecks = 0
            var leavesOrraOnReply = false
            var session: MailEvents.Session? = ReplyHandoffTests.session
            var replyAnswer = MailEvents.Value.reference(.id(MailEvents.Code.outgoingMessage, 77, of: .application))
            var restartsOnReply = false
            var attachFailures: [URL: Int] = [:]
            var quitsOnAttach: URL?
            var restartsOnAttach: URL?
        }

        private let state = Mutex(State())
        private let sendThread: MailEvents.SendThread?
        private let gate: DispatchSemaphore?
        private let attachGate: DispatchSemaphore?

        init(sendThread: MailEvents.SendThread? = nil, gate: DispatchSemaphore? = nil, attachGate: DispatchSemaphore? = nil) {
            self.sendThread = sendThread
            self.gate = gate
            self.attachGate = attachGate
        }

        var steps: [Step] {
            state.withLock { $0.steps }
        }

        /// How often the handoff asked whether Mail runs.
        var runningChecks: Int {
            state.withLock { $0.runningChecks }
        }

        var mailRunning: Bool {
            get { state.withLock { $0.mailRunning } }
            set { state.withLock { $0.mailRunning = newValue } }
        }

        var copyWorks: Bool {
            get { state.withLock { $0.copyWorks } }
            set { state.withLock { $0.copyWorks = newValue } }
        }

        /// The error code of Mail's answer to the reply, nil when Mail makes it.
        var replyFailure: Int? {
            get { state.withLock { $0.replyFailure } }
            set { state.withLock { $0.replyFailure = newValue } }
        }

        /// Whether Mail quits while it makes the reply.
        var quitsOnReply: Bool {
            get { state.withLock { $0.quitsOnReply } }
            set { state.withLock { $0.quitsOnReply = newValue } }
        }

        /// How often the handoff asked whether Orra is in front.
        var activeChecks: Int {
            state.withLock { $0.activeChecks }
        }

        /// Whether the user goes to another app while Mail makes the reply.
        var leavesOrraOnReply: Bool {
            get { state.withLock { $0.leavesOrraOnReply } }
            set { state.withLock { $0.leavesOrraOnReply = newValue } }
        }

        /// What Mail answers to the reply, outgoing message id 77 unless a test sets it.
        var replyAnswer: MailEvents.Value {
            get { state.withLock { $0.replyAnswer } }
            set { state.withLock { $0.replyAnswer = newValue } }
        }

        /// Whether Mail quits and starts again while it makes the reply.
        var restartsOnReply: Bool {
            get { state.withLock { $0.restartsOnReply } }
            set { state.withLock { $0.restartsOnReply = newValue } }
        }

        /// The error code of Mail's answer to the attachment of each file, none when Mail
        /// takes it.
        var attachFailures: [URL: Int] {
            get { state.withLock { $0.attachFailures } }
            set { state.withLock { $0.attachFailures = newValue } }
        }

        /// The file whose attachment Mail quits on.
        var quitsOnAttach: URL? {
            get { state.withLock { $0.quitsOnAttach } }
            set { state.withLock { $0.quitsOnAttach = newValue } }
        }

        /// The file after whose attachment Mail quits and starts again.
        var restartsOnAttach: URL? {
            get { state.withLock { $0.restartsOnAttach } }
            set { state.withLock { $0.restartsOnAttach = newValue } }
        }

        @MainActor
        func handoff() -> ReplyHandoff {
            ReplyHandoff(
                copy: { text in
                    self.state.withLock { state in
                        state.steps.append(.copy(text))
                        return state.copyWorks
                    }
                },
                mail: MailBridge(events: MailEvents(
                    isRunning: {
                        self.state.withLock { state in
                            state.runningChecks += 1
                            return state.mailRunning
                        }
                    },
                    send: { request in
                        guard let thread = self.sendThread else {
                            return try self.send(request)
                        }
                        return try await thread.run { try self.send(request) }
                    },
                    permission: { _ in 0 },
                    session: { self.state.withLock { $0.session } }
                )),
                isOrraActive: {
                    self.state.withLock { state in
                        state.activeChecks += 1
                        return state.orraActive
                    }
                },
                bringMailToFront: { self.state.withLock { $0.steps.append(.front) } }
            )
        }

        private func send(_ request: Request) throws -> MailEvents.Value {
            if case .attach(let file, _, let session) = request {
                return try attach(request, file: file, in: session)
            }
            let value = try state.withLock { state in
                state.steps.append(.send(request))
                if state.quitsOnReply {
                    state.mailRunning = false
                    state.session = nil
                }
                if state.restartsOnReply {
                    state.session = ReplyHandoffTests.laterSession
                }
                if state.leavesOrraOnReply {
                    state.orraActive = false
                }
                if let code = state.replyFailure {
                    throw MailEvents.Failure(code: code)
                }
                return state.replyAnswer
            }
            gate?.wait()
            return value
        }

        /// The attach event as MailEvents' send thread treats it: refused with -600 when
        /// another Mail runs than the one of the reply, else Mail's answer for the file.
        private func attach(_ request: Request, file: URL, in session: MailEvents.Session) throws -> MailEvents.Value {
            let value = try state.withLock { state in
                guard state.session == session else {
                    throw MailEvents.Failure(code: -600)
                }
                state.steps.append(.send(request))
                if state.quitsOnAttach == file {
                    state.mailRunning = false
                    state.session = nil
                }
                if state.restartsOnAttach == file {
                    state.session = ReplyHandoffTests.laterSession
                }
                if let code = state.attachFailures[file] {
                    throw MailEvents.Failure(code: code)
                }
                return MailEvents.Value.missing
            }
            attachGate?.wait()
            return value
        }
    }
}
