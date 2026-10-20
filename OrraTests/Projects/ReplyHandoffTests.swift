import Foundation
import Synchronization
import Testing
@testable import Orra

/// The reply handoff with a fake clipboard, a fake Mail behind the real MailBridge and a fake
/// activation, which record what happened in order. No test touches a pasteboard, sends an
/// Apple Event or brings an app to the front.
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
    func openReplyCopiesThenRepliesThenBringsMailToTheFront(all: Bool) async {
        let fixture = Fixture()
        let outcome = await fixture.handoff().openReply(Self.draft, to: Self.message, all: all)
        #expect(outcome == .replyOpened)
        #expect(fixture.steps == [.copy(Self.draft), .send(.reply(to: Self.message.reference, all: all)), .front])
    }

    @Test func theDraftIsCopiedAsItIs() async {
        let fixture = Fixture()
        let draft = "  王经理您好：\n\n样品周五发出。\n\n"
        #expect(await fixture.handoff().openReply(draft, to: Self.message, all: false) == .replyOpened)
        #expect(fixture.steps.first == .copy(draft))
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

    @Test func aReplyCancelledBeforeMailIsAskedOnlyCopies() async {
        let fixture = Fixture()
        fixture.cancelsReply = true
        #expect(await fixture.handoff().openReply(Self.draft, to: Self.message, all: false) == .copied)
        #expect(fixture.steps == [.copy(Self.draft)])
    }

    @Test func copyOnlyAsksNothingOfMail() {
        let fixture = Fixture()
        #expect(fixture.handoff().copyOnly(Self.draft) == .copied)
        #expect(fixture.steps == [.copy(Self.draft)])
        #expect(fixture.runningChecks == 0)
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

    /// The clipboard, Mail and the activation, as a test sets them, with what each was asked.
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
            var cancelsReply = false
        }

        private let state = Mutex(State())

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

        /// Whether the caller is cancelled before its turn on the send thread, which then
        /// sends nothing.
        var cancelsReply: Bool {
            get { state.withLock { $0.cancelsReply } }
            set { state.withLock { $0.cancelsReply = newValue } }
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
                    send: { request in try self.send(request) },
                    permission: { _ in 0 }
                )),
                bringMailToFront: { self.state.withLock { $0.steps.append(.front) } }
            )
        }

        private func send(_ request: Request) throws -> MailEvents.Value {
            try state.withLock { state in
                if state.cancelsReply {
                    throw CancellationError()
                }
                state.steps.append(.send(request))
                if state.quitsOnReply {
                    state.mailRunning = false
                }
                if let code = state.replyFailure {
                    throw MailEvents.Failure(code: code)
                }
                return .missing
            }
        }
    }
}
