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
        .cancelled,
        .processingFinished,
    ]

    /// Every state and event pair with the decided outcome. See the doc comment
    /// on PushToTalkStateMachine for the reasoning behind the ignored rows.
    static let table: [Row] = [
        Row(from: .idle, event: .pressed(isRepeat: false), to: .listening, transition: .startedListening),
        Row(from: .idle, event: .pressed(isRepeat: true), to: .idle, transition: nil),
        Row(from: .idle, event: .released, to: .idle, transition: nil),
        Row(from: .idle, event: .cancelled, to: .idle, transition: nil),
        Row(from: .idle, event: .processingFinished, to: .idle, transition: nil),

        Row(from: .listening, event: .pressed(isRepeat: false), to: .listening, transition: nil),
        Row(from: .listening, event: .pressed(isRepeat: true), to: .listening, transition: nil),
        Row(from: .listening, event: .released, to: .processing, transition: .startedProcessing),
        Row(from: .listening, event: .cancelled, to: .idle, transition: .cancelledListening),
        Row(from: .listening, event: .processingFinished, to: .listening, transition: nil),

        Row(from: .processing, event: .pressed(isRepeat: false), to: .processing, transition: nil),
        Row(from: .processing, event: .pressed(isRepeat: true), to: .processing, transition: nil),
        Row(from: .processing, event: .released, to: .processing, transition: nil),
        Row(from: .processing, event: .cancelled, to: .processing, transition: nil),
        Row(from: .processing, event: .processingFinished, to: .idle, transition: .finished),
    ]

    /// Drives a fresh machine into `state` using real events only.
    private func makeMachine(in state: Machine.State) -> Machine {
        var machine = Machine()
        switch state {
        case .idle:
            break
        case .listening:
            _ = machine.handle(.pressed(isRepeat: false))
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
}
