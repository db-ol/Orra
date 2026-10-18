import Testing
@testable import Orra

struct PushToTalkStateMachineTests {
    typealias Machine = PushToTalkStateMachine

    /// One row of the full transition table.
    struct Row: Sendable, CustomTestStringConvertible {
        let from: Machine.State
        let event: Machine.Event
        let to: Machine.State
        let transition: Machine.Transition?

        var testDescription: String {
            let outcome = transition.map { "\($0)" } ?? "ignored"
            return "\(from) + \(event) -> \(to), \(outcome)"
        }
    }

    static let allEvents: [Machine.Event] = [
        .pressed(isRepeat: false),
        .pressed(isRepeat: true),
        .released,
        .tapped,
        .doublePressed,
        .cancelled,
        .processingFinished,
        .armed,
        .pressedAfterLimit,
    ]

    /// Every state and event pair with the decided outcome. See the doc comment
    /// on PushToTalkStateMachine for the reasoning behind the ignored rows.
    static let table: [Row] = [
        Row(from: .idle, event: .pressed(isRepeat: false), to: .listening, transition: .startedListening),
        Row(from: .idle, event: .pressed(isRepeat: true), to: .idle, transition: nil),
        Row(from: .idle, event: .released, to: .idle, transition: nil),
        Row(from: .idle, event: .tapped, to: .idle, transition: nil),
        Row(from: .idle, event: .doublePressed, to: .handsFree, transition: .startedHandsFree),
        Row(from: .idle, event: .cancelled, to: .idle, transition: nil),
        Row(from: .idle, event: .processingFinished, to: .idle, transition: nil),
        Row(from: .idle, event: .armed, to: .arming, transition: .startedArming),
        Row(from: .idle, event: .pressedAfterLimit, to: .idle, transition: nil),

        Row(from: .arming, event: .pressed(isRepeat: false), to: .listening, transition: .confirmedArming),
        Row(from: .arming, event: .pressed(isRepeat: true), to: .arming, transition: nil),
        Row(from: .arming, event: .released, to: .idle, transition: .droppedArming),
        Row(from: .arming, event: .tapped, to: .idle, transition: .droppedArming),
        Row(from: .arming, event: .doublePressed, to: .handsFree, transition: .confirmedArming),
        Row(from: .arming, event: .cancelled, to: .idle, transition: .droppedArming),
        Row(from: .arming, event: .processingFinished, to: .arming, transition: nil),
        Row(from: .arming, event: .armed, to: .arming, transition: nil),
        Row(from: .arming, event: .pressedAfterLimit, to: .idle, transition: .droppedArming),

        Row(from: .listening, event: .pressed(isRepeat: false), to: .listening, transition: nil),
        Row(from: .listening, event: .pressed(isRepeat: true), to: .listening, transition: nil),
        Row(from: .listening, event: .released, to: .processing, transition: .startedProcessing),
        Row(from: .listening, event: .tapped, to: .waitingForSecondPress, transition: .awaitingSecondPress),
        Row(from: .listening, event: .doublePressed, to: .handsFree, transition: .switchedToHandsFree),
        Row(from: .listening, event: .cancelled, to: .idle, transition: .cancelledListening),
        Row(from: .listening, event: .processingFinished, to: .listening, transition: nil),
        Row(from: .listening, event: .armed, to: .listening, transition: nil),
        Row(from: .listening, event: .pressedAfterLimit, to: .listening, transition: nil),

        Row(from: .waitingForSecondPress, event: .pressed(isRepeat: false), to: .listening, transition: .resumedListening),
        Row(from: .waitingForSecondPress, event: .pressed(isRepeat: true), to: .waitingForSecondPress, transition: nil),
        Row(from: .waitingForSecondPress, event: .released, to: .waitingForSecondPress, transition: nil),
        Row(from: .waitingForSecondPress, event: .tapped, to: .waitingForSecondPress, transition: nil),
        Row(from: .waitingForSecondPress, event: .doublePressed, to: .handsFree, transition: .switchedToHandsFree),
        Row(from: .waitingForSecondPress, event: .cancelled, to: .idle, transition: .cancelledListening),
        Row(from: .waitingForSecondPress, event: .processingFinished, to: .waitingForSecondPress, transition: nil),
        Row(from: .waitingForSecondPress, event: .armed, to: .waitingForSecondPress, transition: nil),
        Row(from: .waitingForSecondPress, event: .pressedAfterLimit, to: .waitingForSecondPress, transition: nil),

        Row(from: .handsFree, event: .pressed(isRepeat: false), to: .handsFree, transition: nil),
        Row(from: .handsFree, event: .pressed(isRepeat: true), to: .handsFree, transition: nil),
        Row(from: .handsFree, event: .released, to: .processing, transition: .startedProcessing),
        Row(from: .handsFree, event: .tapped, to: .handsFree, transition: nil),
        Row(from: .handsFree, event: .doublePressed, to: .handsFree, transition: nil),
        Row(from: .handsFree, event: .cancelled, to: .idle, transition: .cancelledListening),
        Row(from: .handsFree, event: .processingFinished, to: .handsFree, transition: nil),
        Row(from: .handsFree, event: .armed, to: .handsFree, transition: nil),
        Row(from: .handsFree, event: .pressedAfterLimit, to: .handsFree, transition: nil),

        Row(from: .processing, event: .pressed(isRepeat: false), to: .processing, transition: nil),
        Row(from: .processing, event: .pressed(isRepeat: true), to: .processing, transition: nil),
        Row(from: .processing, event: .released, to: .processing, transition: nil),
        Row(from: .processing, event: .tapped, to: .processing, transition: nil),
        Row(from: .processing, event: .doublePressed, to: .processing, transition: nil),
        Row(from: .processing, event: .cancelled, to: .processing, transition: nil),
        Row(from: .processing, event: .processingFinished, to: .idle, transition: .finished),
        Row(from: .processing, event: .armed, to: .processing, transition: nil),
        Row(from: .processing, event: .pressedAfterLimit, to: .processing, transition: nil),
    ]

    /// Drives a fresh machine into `state` using real events only.
    private func makeMachine(in state: Machine.State) -> Machine {
        var machine = Machine()
        switch state {
        case .idle:
            break
        case .arming:
            _ = machine.handle(.armed)
        case .listening:
            _ = machine.handle(.pressed(isRepeat: false))
        case .waitingForSecondPress:
            _ = machine.handle(.pressed(isRepeat: false))
            _ = machine.handle(.tapped)
        case .handsFree:
            _ = machine.handle(.doublePressed)
        case .processing:
            _ = machine.handle(.pressed(isRepeat: false))
            _ = machine.handle(.released)
        }
        precondition(machine.state == state, "helper failed to reach \(state)")
        return machine
    }

    @Test func startsIdle() {
        #expect(Machine().state == .idle)
    }

    @Test func pressReleaseFinishCompletesOneCycle() {
        var machine = Machine()
        #expect(machine.handle(.pressed(isRepeat: false)) == .startedListening)
        #expect(machine.state == .listening)
        #expect(machine.handle(.released) == .startedProcessing)
        #expect(machine.state == .processing)
        #expect(machine.handle(.processingFinished) == .finished)
        #expect(machine.state == .idle)
    }

    @Test func machineIsReusableAfterACycle() {
        var machine = makeMachine(in: .processing)
        _ = machine.handle(.processingFinished)
        #expect(machine.handle(.pressed(isRepeat: false)) == .startedListening)
        #expect(machine.state == .listening)
    }

    @Test(arguments: Machine.State.allCases)
    func keyRepeatIsIgnored(in state: Machine.State) {
        var machine = makeMachine(in: state)
        #expect(machine.handle(.pressed(isRepeat: true)) == nil)
        #expect(machine.state == state)
    }

    @Test func releaseWithoutPressIsIgnored() {
        var machine = Machine()
        #expect(machine.handle(.released) == nil)
        #expect(machine.state == .idle)
    }

    @Test func pressWhileListeningIsIgnored() {
        var machine = makeMachine(in: .listening)
        #expect(machine.handle(.pressed(isRepeat: false)) == nil)
        #expect(machine.state == .listening)
    }

    @Test func pressDuringProcessingIsIgnored() {
        var machine = makeMachine(in: .processing)
        #expect(machine.handle(.pressed(isRepeat: false)) == nil)
        #expect(machine.state == .processing)
        #expect(machine.handle(.released) == nil)
        #expect(machine.state == .processing)
    }

    @Test func cancelWhileListeningReturnsToIdle() {
        var machine = makeMachine(in: .listening)
        #expect(machine.handle(.cancelled) == .cancelledListening)
        #expect(machine.state == .idle)
        #expect(machine.handle(.released) == nil)
        #expect(machine.state == .idle)
    }

    @Test(arguments: [Machine.State.idle, .processing])
    func cancelOutsideListeningIsIgnored(in state: Machine.State) {
        var machine = makeMachine(in: state)
        #expect(machine.handle(.cancelled) == nil)
        #expect(machine.state == state)
    }

    @Test(arguments: [Machine.State.idle, .listening])
    func staleProcessingFinishedIsIgnored(in state: Machine.State) {
        var machine = makeMachine(in: state)
        #expect(machine.handle(.processingFinished) == nil)
        #expect(machine.state == state)
    }

    @Test(arguments: table)
    func transitionTable(_ row: Row) {
        var machine = makeMachine(in: row.from)
        #expect(machine.handle(row.event) == row.transition)
        #expect(machine.state == row.to)
    }

    @Test func tableCoversEveryStateAndEventOnce() {
        let covered = Self.table.map { "\($0.from)|\($0.event)" }
        #expect(Set(covered).count == covered.count)
        for state in Machine.State.allCases {
            for event in Self.allEvents {
                #expect(covered.contains("\(state)|\(event)"), "missing row for \(state) and \(event)")
            }
        }
        #expect(covered.count == Machine.State.allCases.count * Self.allEvents.count)
    }

    // MARK: Hands free

    @Test func aTapThenADoublePressKeepsTheRecordingAndGoesHandsFree() {
        var machine = Machine()
        #expect(machine.handle(.pressed(isRepeat: false)) == .startedListening)
        #expect(machine.handle(.tapped) == .awaitingSecondPress)
        #expect(machine.isRecording)
        #expect(machine.handle(.doublePressed) == .switchedToHandsFree)
        #expect(machine.state == .handsFree)
        // The release of the second press is not sent. The next press on its own ends it.
        #expect(machine.handle(.released) == .startedProcessing)
        #expect(machine.handle(.processingFinished) == .finished)
        #expect(machine.state == .idle)
    }

    @Test func theSecondPressKeepsTheRecordingAndItsReleaseDecides() {
        // A quick second press: hands free at its release.
        var quick = makeMachine(in: .waitingForSecondPress)
        #expect(quick.handle(.pressed(isRepeat: false)) == .resumedListening)
        #expect(quick.isRecording)
        #expect(quick.handle(.doublePressed) == .switchedToHandsFree)
        #expect(quick.state == .handsFree)
        // A long second press: a hold, processed at its release.
        var hold = makeMachine(in: .waitingForSecondPress)
        #expect(hold.handle(.pressed(isRepeat: false)) == .resumedListening)
        #expect(hold.handle(.released) == .startedProcessing)
    }

    @Test func aTapWithoutASecondPressIsDiscarded() {
        var machine = makeMachine(in: .waitingForSecondPress)
        #expect(machine.handle(.cancelled) == .cancelledListening)
        #expect(machine.state == .idle)
        // A slow second press is an ordinary hold.
        #expect(machine.handle(.pressed(isRepeat: false)) == .startedListening)
        #expect(machine.handle(.released) == .startedProcessing)
    }

    @Test func aDoublePressFromIdleStartsHandsFree() {
        var machine = Machine()
        #expect(machine.handle(.doublePressed) == .startedHandsFree)
        #expect(machine.isRecording)
        #expect(machine.handle(.cancelled) == .cancelledListening)
        #expect(machine.state == .idle)
    }

    @Test func pressesDuringHandsFreeDoNotRestartIt() {
        var machine = makeMachine(in: .handsFree)
        for event in [Machine.Event.pressed(isRepeat: false), .tapped, .doublePressed, .processingFinished] {
            #expect(machine.handle(event) == nil)
            #expect(machine.state == .handsFree)
        }
    }

    @Test func aDoublePressDuringProcessingIsIgnored() {
        var machine = makeMachine(in: .processing)
        #expect(machine.handle(.doublePressed) == nil)
        #expect(machine.state == .processing)
    }

    @Test func onlyTheListeningStatesRecord() {
        let recording = Machine.State.allCases.filter { makeMachine(in: $0).isRecording }
        #expect(recording == [.arming, .listening, .waitingForSecondPress, .handsFree])
    }

    // MARK: Early capture

    @Test func aPressThatCountsKeepsTheEarlyCapture() {
        var machine = Machine()
        #expect(machine.handle(.armed) == .startedArming)
        #expect(machine.state == .arming)
        #expect(machine.isRecording)
        // The press counts after its wait: the same recording becomes the dictation.
        #expect(machine.handle(.pressed(isRepeat: false)) == .confirmedArming)
        #expect(machine.state == .listening)
        #expect(machine.handle(.released) == .startedProcessing)
    }

    @Test func aReleaseThatStartsHandsFreeKeepsTheEarlyCapture() {
        // Press to start and stop, or the second press of a double press, released before
        // the wait is over.
        var machine = makeMachine(in: .arming)
        #expect(machine.handle(.doublePressed) == .confirmedArming)
        #expect(machine.state == .handsFree)
        #expect(machine.handle(.released) == .startedProcessing)
    }

    @Test(arguments: [Machine.Event.cancelled, .released, .tapped])
    func aPressThatNeverCountsDropsTheEarlyCapture(_ event: Machine.Event) {
        var machine = makeMachine(in: .arming)
        #expect(machine.handle(event) == .droppedArming)
        #expect(machine.state == .idle)
        #expect(!machine.isRecording)
        // A later press starts its own recording.
        #expect(machine.handle(.pressed(isRepeat: false)) == .startedListening)
    }

    @Test(arguments: [Machine.State.arming, .listening, .waitingForSecondPress, .handsFree, .processing])
    func armedIsIgnoredOutsideIdle(in state: Machine.State) {
        var machine = makeMachine(in: state)
        #expect(machine.handle(.armed) == nil)
        #expect(machine.state == state)
    }
}
