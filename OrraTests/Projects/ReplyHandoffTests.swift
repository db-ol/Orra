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

    @Test(arguments: [false, true])
    func openReplyCopiesRepliesCopiesAgainThenBringsMailToTheFront(all: Bool) async {
        let fixture = Fixture()
        let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: all)
        #expect(outcome == .replyOpened)
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
        #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: false) == .replyOpened)
        #expect(fixture.steps == [.copy(Self.draft), .send(.reply(to: Self.message.reference, all: false))])
        #expect(fixture.activeChecks == 1)
    }

    @Test func theDraftIsCopiedAsItIs() async {
        let fixture = Fixture()
        let draft = "  王经理您好：\n\n样品周五发出。\n\n"
        #expect(await fixture.handoff().openReply(draft, to: Self.message, all: false) == .replyOpened)
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
        #expect(await reply.value == .replyOpened)
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
        #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: false) == .notCopied)
        #expect(fixture.handoff().copyOnly(Self.draft) == .notCopied)
        #expect(fixture.steps == [.copy(Self.draft), .copy(Self.draft)])
        #expect(fixture.runningChecks == 0)
    }

    /// The clipboard, Mail, whether Orra is in front and the activation, as a test sets them,
    /// with what each was asked. With a send thread, Mail's events wait their turn on it.
    /// With a gate, Mail answers an event only once the test signals it.
    private final class Fixture: Sendable {
        enum Step: Equatable, Sendable {
            case copy(String)
            case send(Request)
            case front
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
        }

        private let state = Mutex(State())
        private let sendThread: MailEvents.SendThread?
        private let gate: DispatchSemaphore?

        init(sendThread: MailEvents.SendThread? = nil, gate: DispatchSemaphore? = nil) {
            self.sendThread = sendThread
            self.gate = gate
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
                    session: { nil }
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
            let value = try state.withLock { state in
                state.steps.append(.send(request))
                if state.quitsOnReply {
                    state.mailRunning = false
                }
                if state.leavesOrraOnReply {
                    state.orraActive = false
                }
                if let code = state.replyFailure {
                    throw MailEvents.Failure(code: code)
                }
                return MailEvents.Value.missing
            }
            gate?.wait()
            return value
        }
    }
}
