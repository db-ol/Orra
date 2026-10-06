import CoreGraphics
import Testing
@testable import Orra

struct TalkKeyDetectorTests {
    typealias Decision = TalkKeyDetector.Decision

    // Virtual key codes from HIToolbox Events.h.
    static let fn: Int64 = 63
    static let shift: Int64 = 56
    static let command: Int64 = 55
    static let leftControl: Int64 = 59
    static let rightControl: Int64 = 62
    static let delete: Int64 = 51
    static let c: Int64 = 8
    static let leftArrow: Int64 = 123
    static let globe: Int64 = 179

    // Device dependent bits from IOKit's IOLLEvent.h.
    static let leftControlBit = CGEventFlags(rawValue: 0x0000_0001)
    static let rightControlBit = CGEventFlags(rawValue: 0x0000_2000)

    private func fnDown(_ detector: inout TalkKeyDetector, with modifiers: CGEventFlags = []) -> Decision {
        detector.handle(type: .flagsChanged, keyCode: Self.fn, flags: modifiers.union(.maskSecondaryFn))
    }

    private func fnUp(_ detector: inout TalkKeyDetector, with modifiers: CGEventFlags = []) -> Decision {
        detector.handle(type: .flagsChanged, keyCode: Self.fn, flags: modifiers)
    }

    private func rightControlDown(_ detector: inout TalkKeyDetector, with modifiers: CGEventFlags = []) -> Decision {
        detector.handle(type: .flagsChanged, keyCode: Self.rightControl, flags: modifiers.union([.maskControl, Self.rightControlBit]))
    }

    private func rightControlUp(_ detector: inout TalkKeyDetector, with modifiers: CGEventFlags = []) -> Decision {
        detector.handle(type: .flagsChanged, keyCode: Self.rightControl, flags: modifiers)
    }

    /// Drives a fresh detector that listens for fn only into `phase`, using real event
    /// sequences only.
    private func makeFnDetector(in phase: TalkKeyDetector.Phase) -> TalkKeyDetector {
        var detector = TalkKeyDetector(keys: [.fn])
        switch phase {
        case .up:
            break
        case .holding:
            _ = fnDown(&detector)
        case .cancelled:
            _ = fnDown(&detector)
            _ = detector.handle(type: .keyDown, keyCode: Self.delete, flags: .maskSecondaryFn)
        case .passingThrough:
            _ = fnDown(&detector, with: .maskCommand)
        }
        precondition(detector.phase == phase, "helper failed to reach \(phase)")
        return detector
    }

    // MARK: fn, as before the keys became a choice

    @Test func fnAloneIsAHoldAndItsEventsAreSwallowed() {
        var detector = TalkKeyDetector(keys: [.fn])
        #expect(fnDown(&detector) == Decision(event: .pressed(isRepeat: false), swallow: true))
        #expect(detector.phase == .holding(.fn))
        #expect(fnUp(&detector) == Decision(event: .released, swallow: true))
        #expect(detector.phase == .up)
    }

    @Test func capsLockDoesNotPreventAHold() {
        var detector = TalkKeyDetector(keys: [.fn])
        #expect(fnDown(&detector, with: .maskAlphaShift).event == .pressed(isRepeat: false))
        #expect(fnUp(&detector, with: .maskAlphaShift).event == .released)
    }

    @Test(arguments: [CGEventFlags.maskShift, .maskControl, .maskAlternate, .maskCommand])
    func fnWithAnotherModifierPassesThrough(_ modifier: CGEventFlags) {
        var detector = TalkKeyDetector(keys: [.fn])
        #expect(fnDown(&detector, with: modifier) == .passThrough)
        #expect(detector.phase == .passingThrough(.fn))
        #expect(fnUp(&detector, with: modifier) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test func keyDuringHoldCancelsAndPassesThrough() {
        var detector = makeFnDetector(in: .holding(.fn))
        let decision = detector.handle(type: .keyDown, keyCode: Self.delete, flags: .maskSecondaryFn)
        #expect(decision == Decision(event: .cancelled, swallow: false))
        #expect(detector.phase == .cancelled(.fn))
        // The release is still swallowed, because the press was.
        #expect(fnUp(&detector) == Decision(event: nil, swallow: true))
        #expect(detector.phase == .up)
    }

    @Test func modifierDuringHoldCancels() {
        var detector = makeFnDetector(in: .holding(.fn))
        let shiftDown = detector.handle(type: .flagsChanged, keyCode: Self.shift, flags: [.maskSecondaryFn, .maskShift])
        #expect(shiftDown == Decision(event: .cancelled, swallow: false))
        let shiftUp = detector.handle(type: .flagsChanged, keyCode: Self.shift, flags: .maskSecondaryFn)
        #expect(shiftUp == .passThrough)
        #expect(fnUp(&detector) == Decision(event: nil, swallow: true))
        #expect(detector.phase == .up)
    }

    @Test func fnPressedWhileAnotherModifierIsStillDownNeverStartsAHold() {
        // Rollover: Command is still down when Fn goes down and comes up right
        // after. Fn must go down on its own, so there is no hold and nothing is
        // swallowed.
        var detector = TalkKeyDetector(keys: [.fn])
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.command, flags: .maskCommand) == .passThrough)
        #expect(fnDown(&detector, with: .maskCommand) == .passThrough)
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.command, flags: .maskSecondaryFn) == .passThrough)
        #expect(detector.phase == .passingThrough(.fn))
        #expect(fnUp(&detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test func globeKeyCodeDoesNotCancelAHold() {
        var detector = makeFnDetector(in: .holding(.fn))
        #expect(detector.handle(type: .keyDown, keyCode: Self.globe, flags: .maskSecondaryFn) == .passThrough)
        #expect(detector.phase == .holding(.fn))
        #expect(fnUp(&detector).event == .released)
    }

    @Test func arrowKeyWithTheFnFlagDoesNotStartAHold() {
        var detector = TalkKeyDetector(keys: [.fn])
        let decision = detector.handle(type: .keyDown, keyCode: Self.leftArrow, flags: [.maskSecondaryFn, .maskNumericPad])
        #expect(decision == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test func releaseWithoutPressPassesThrough() {
        var detector = TalkKeyDetector(keys: [.fn])
        #expect(fnUp(&detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test(arguments: [TalkKeyDetector.Phase.holding(.fn), .cancelled(.fn)])
    func repeatedFnPressIsSwallowedWithoutAnEvent(in phase: TalkKeyDetector.Phase) {
        var detector = makeFnDetector(in: phase)
        #expect(fnDown(&detector) == Decision(event: nil, swallow: true))
        #expect(detector.phase == phase)
    }

    @Test(arguments: [TalkKeyDetector.Phase.up, .holding(.fn), .cancelled(.fn), .passingThrough(.fn)])
    func otherKeysAreNeverSwallowed(in phase: TalkKeyDetector.Phase) {
        var keyDown = makeFnDetector(in: phase)
        #expect(keyDown.handle(type: .keyDown, keyCode: Self.delete, flags: []).swallow == false)
        var keyUp = makeFnDetector(in: phase)
        #expect(keyUp.handle(type: .keyUp, keyCode: Self.delete, flags: []).swallow == false)
        var modifier = makeFnDetector(in: phase)
        #expect(modifier.handle(type: .flagsChanged, keyCode: Self.command, flags: .maskCommand).swallow == false)
    }

    @Test func keyUpNeverCancelsAHold() {
        var detector = makeFnDetector(in: .holding(.fn))
        #expect(detector.handle(type: .keyUp, keyCode: Self.delete, flags: .maskSecondaryFn) == .passThrough)
        #expect(detector.phase == .holding(.fn))
    }

    @Test func resetCancelsOnlyAHoldInProgress() {
        var holding = makeFnDetector(in: .holding(.fn))
        #expect(holding.reset() == .cancelled)
        #expect(holding.phase == .up)
        for phase in [TalkKeyDetector.Phase.up, .cancelled(.fn), .passingThrough(.fn)] {
            var detector = makeFnDetector(in: phase)
            #expect(detector.reset() == nil)
            #expect(detector.phase == .up)
        }
    }

    @Test func fnPassesThroughWhenItIsNotATalkKey() {
        // With the default keys, fn keeps its system action, such as the emoji picker.
        var detector = TalkKeyDetector(keys: TalkKey.defaultKeys)
        #expect(fnDown(&detector) == .passThrough)
        #expect(detector.phase == .up)
        #expect(fnUp(&detector) == .passThrough)
    }

    // MARK: Right Control, the default

    @Test func rightControlAloneIsAHoldAndItsEventsPassThrough() {
        var detector = TalkKeyDetector(keys: TalkKey.defaultKeys)
        #expect(rightControlDown(&detector) == Decision(event: .pressed(isRepeat: false), swallow: false))
        #expect(detector.phase == .holding(.rightControl))
        #expect(rightControlUp(&detector) == Decision(event: .released, swallow: false))
        #expect(detector.phase == .up)
    }

    @Test func rightControlWorksOnAKeyboardWithoutLeftAndRightBits() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.rightControl, flags: .maskControl).event == .pressed(isRepeat: false))
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.rightControl, flags: []).event == .released)
        #expect(detector.phase == .up)
    }

    @Test func leftControlNeverStartsAHold() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.leftControl, flags: [.maskControl, Self.leftControlBit]) == .passThrough)
        #expect(detector.phase == .up)
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.leftControl, flags: []) == .passThrough)
    }

    @Test func rightControlWhileLeftControlIsDownBelongsToAShortcut() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = detector.handle(type: .flagsChanged, keyCode: Self.leftControl, flags: [.maskControl, Self.leftControlBit])
        #expect(rightControlDown(&detector, with: Self.leftControlBit) == .passThrough)
        #expect(detector.phase == .passingThrough(.rightControl))
        #expect(rightControlUp(&detector, with: [.maskControl, Self.leftControlBit]) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test func leftControlDuringARightControlHoldCancelsIt() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = rightControlDown(&detector)
        let leftDown = detector.handle(type: .flagsChanged, keyCode: Self.leftControl, flags: [.maskControl, Self.leftControlBit, Self.rightControlBit])
        #expect(leftDown == Decision(event: .cancelled, swallow: false))
        // Right Control comes up while left Control stays down. The left bit is still
        // set, so the event reads as a release.
        #expect(rightControlUp(&detector, with: [.maskControl, Self.leftControlBit]) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test(arguments: [CGEventFlags.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn])
    func rightControlWithAnotherModifierPassesThrough(_ modifier: CGEventFlags) {
        var detector = TalkKeyDetector(keys: [.rightControl])
        #expect(rightControlDown(&detector, with: modifier) == .passThrough)
        #expect(detector.phase == .passingThrough(.rightControl))
        #expect(rightControlUp(&detector, with: modifier) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test(arguments: [TalkKey.rightOption, .rightCommand])
    func theOtherRightHandModifiersWorkTheSameWay(_ key: TalkKey) throws {
        var detector = TalkKeyDetector(keys: [key])
        let sharedFlag = try #require(key.sharedFlag)
        let leftKeyFlag = try #require(key.leftKeyFlag)
        let down = detector.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [sharedFlag, key.downFlag])
        #expect(down == Decision(event: .pressed(isRepeat: false), swallow: false))
        #expect(detector.handle(type: .flagsChanged, keyCode: key.keyCode, flags: []) == Decision(event: .released, swallow: false))
        // With the left key of the pair already down, it is a shortcut.
        #expect(detector.handle(type: .flagsChanged, keyCode: key.keyCode, flags: [sharedFlag, key.downFlag, leftKeyFlag]) == .passThrough)
        #expect(detector.phase == .passingThrough(key))
    }

    // MARK: Clicks

    @Test func aClickEndsAHoldOfARightHandKey() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = rightControlDown(&detector)
        #expect(detector.cancelForClick() == .cancelled)
        #expect(detector.phase == .cancelled(.rightControl))
        #expect(rightControlUp(&detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test func aClickLeavesAnFnHoldAlone() {
        var detector = makeFnDetector(in: .holding(.fn))
        #expect(detector.cancelForClick() == nil)
        #expect(detector.phase == .holding(.fn))
        #expect(fnUp(&detector).event == .released)
    }

    @Test(arguments: [TalkKeyDetector.Phase.up, .cancelled(.fn), .passingThrough(.fn)])
    func aClickOutsideAHoldChangesNothing(in phase: TalkKeyDetector.Phase) {
        var detector = makeFnDetector(in: phase)
        #expect(detector.cancelForClick() == nil)
        #expect(detector.phase == phase)
    }

    @Test func rightControlClickIsAShortcutNotADictation() {
        var detector = TalkKeyDetector(keys: TalkKey.defaultKeys)
        var machine = PushToTalkStateMachine()
        var transitions: [PushToTalkStateMachine.Transition] = []
        func feed(_ event: PushToTalkStateMachine.Event?) {
            if let event, let transition = machine.handle(event) {
                transitions.append(transition)
            }
        }
        feed(rightControlDown(&detector).event)
        feed(detector.cancelForClick())
        feed(rightControlUp(&detector).event)
        #expect(transitions == [.startedListening, .cancelledListening])
        #expect(machine.state == .idle)
    }

    // MARK: Keyboards without left and right bits

    @Test func withoutBitsRightControlReleasedWhileLeftControlIsDownLeavesNothingStuck() {
        var detector = TalkKeyDetector(keys: [.rightControl, .fn])
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.rightControl, flags: .maskControl).event == .pressed(isRepeat: false))
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.leftControl, flags: .maskControl) == Decision(event: .cancelled, swallow: false))
        // Right Control comes up while left Control is still down. Without bits the flags
        // look the same as at the press.
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.rightControl, flags: .maskControl) == .passThrough)
        #expect(detector.phase == .up)
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.leftControl, flags: []) == .passThrough)
        // Both talk keys still work afterwards.
        #expect(fnDown(&detector).event == .pressed(isRepeat: false))
        #expect(fnUp(&detector).event == .released)
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.rightControl, flags: .maskControl).event == .pressed(isRepeat: false))
    }

    @Test func withoutBitsLeftControlFirstIsAShortcutNotADictation() {
        let run = transitions(keys: [.rightControl], for: [
            (.flagsChanged, Self.leftControl, .maskControl),
            (.flagsChanged, Self.rightControl, .maskControl),
            // Right Control comes up while left Control is still down.
            (.flagsChanged, Self.rightControl, .maskControl),
            (.flagsChanged, Self.leftControl, []),
        ])
        // Such a keyboard does not show left Control at the press, so the recording
        // starts, but the release ends it as a shortcut instead of transcribing it.
        #expect(run.transitions == [.startedListening, .cancelledListening])
        #expect(run.machine.state == .idle)
    }

    // MARK: Several keys

    @Test func eitherOfTwoTalkKeysStartsAHold() {
        var detector = TalkKeyDetector(keys: [.fn, .rightControl])
        #expect(fnDown(&detector).event == .pressed(isRepeat: false))
        #expect(fnUp(&detector).event == .released)
        #expect(rightControlDown(&detector).event == .pressed(isRepeat: false))
        #expect(rightControlUp(&detector).event == .released)
        #expect(detector.phase == .up)
    }

    @Test func aSecondTalkKeyDuringAHoldCancelsIt() {
        var detector = TalkKeyDetector(keys: [.fn, .rightControl])
        _ = fnDown(&detector)
        #expect(rightControlDown(&detector, with: .maskSecondaryFn) == Decision(event: .cancelled, swallow: false))
        #expect(detector.phase == .cancelled(.fn))
        #expect(rightControlUp(&detector, with: .maskSecondaryFn) == .passThrough)
        #expect(fnUp(&detector) == Decision(event: nil, swallow: true))
        #expect(detector.phase == .up)
    }

    @Test func removingTheHeldKeyEndsTheHold() {
        var detector = TalkKeyDetector(keys: [.fn, .rightControl])
        _ = rightControlDown(&detector)
        #expect(detector.setKeys([.fn]) == .cancelled)
        #expect(detector.phase == .up)
        // Its release is now just another modifier.
        #expect(rightControlUp(&detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test func addingAKeyKeepsTheHold() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = rightControlDown(&detector)
        #expect(detector.setKeys([.rightControl, .fn]) == nil)
        #expect(detector.phase == .holding(.rightControl))
        #expect(rightControlUp(&detector).event == .released)
    }

    // MARK: Into the state model

    /// Feeds raw events through the detector into the state model and returns
    /// the transitions, the way HotkeyTap and PushToTalkController do.
    private func transitions(keys: Set<TalkKey>, for events: [(CGEventType, Int64, CGEventFlags)]) -> (transitions: [PushToTalkStateMachine.Transition], machine: PushToTalkStateMachine) {
        var detector = TalkKeyDetector(keys: keys)
        var machine = PushToTalkStateMachine()
        var result: [PushToTalkStateMachine.Transition] = []
        for (type, keyCode, flags) in events {
            if let event = detector.handle(type: type, keyCode: keyCode, flags: flags).event,
               let transition = machine.handle(event) {
                result.append(transition)
            }
        }
        return (result, machine)
    }

    @Test func fnHoldStartsListeningAndReleaseStartsProcessing() {
        let run = transitions(keys: [.fn], for: [
            (.flagsChanged, Self.fn, .maskSecondaryFn),
            (.flagsChanged, Self.fn, []),
        ])
        #expect(run.transitions == [.startedListening, .startedProcessing])
        #expect(run.machine.state == .processing)
    }

    @Test func fnDeleteNeverReachesProcessing() {
        let run = transitions(keys: [.fn], for: [
            (.flagsChanged, Self.fn, .maskSecondaryFn),
            (.keyDown, Self.delete, .maskSecondaryFn),
            (.flagsChanged, Self.fn, []),
        ])
        #expect(run.transitions == [.startedListening, .cancelledListening])
        #expect(run.machine.state == .idle)
    }

    @Test func rightControlHoldStartsListeningAndReleaseStartsProcessing() {
        let run = transitions(keys: TalkKey.defaultKeys, for: [
            (.flagsChanged, Self.rightControl, [.maskControl, Self.rightControlBit]),
            (.flagsChanged, Self.rightControl, []),
        ])
        #expect(run.transitions == [.startedListening, .startedProcessing])
        #expect(run.machine.state == .processing)
    }

    /// A small random number generator with a fixed seed, so every run is the same.
    struct SplitMix {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Plays thousands of random presses and releases of eight modifiers on a keyboard
    /// that sets left and right bits, with key downs, clicks, changes of talk keys and
    /// resets mixed in, and checks what must always hold: only fn's own events are ever
    /// swallowed, a swallowed fn release always follows a swallowed fn press, and once every
    /// key is up nothing is held and nothing is listening.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func randomSequencesKeepTheRules(seed: UInt64) {
        struct Modifier {
            let keyCode: Int64
            let shared: CGEventFlags
            let bit: CGEventFlags
        }
        let modifiers = [
            Modifier(keyCode: Self.fn, shared: .maskSecondaryFn, bit: []),
            Modifier(keyCode: Self.leftControl, shared: .maskControl, bit: Self.leftControlBit),
            Modifier(keyCode: Self.rightControl, shared: .maskControl, bit: Self.rightControlBit),
            Modifier(keyCode: 58, shared: .maskAlternate, bit: CGEventFlags(rawValue: 0x20)),
            Modifier(keyCode: 61, shared: .maskAlternate, bit: CGEventFlags(rawValue: 0x40)),
            Modifier(keyCode: Self.command, shared: .maskCommand, bit: CGEventFlags(rawValue: 0x08)),
            Modifier(keyCode: 54, shared: .maskCommand, bit: CGEventFlags(rawValue: 0x10)),
            Modifier(keyCode: Self.shift, shared: .maskShift, bit: CGEventFlags(rawValue: 0x02)),
        ]
        let keySets: [Set<TalkKey>] = [[.rightControl], [.fn], [.rightControl, .fn], [.rightOption, .rightCommand], Set(TalkKey.allCases)]
        var random = SplitMix(state: seed)
        var down = Array(repeating: false, count: modifiers.count)
        var detector = TalkKeyDetector(keys: keySets[Int(seed) % keySets.count])
        var machine = PushToTalkStateMachine()
        var fnPressWasSwallowed = false

        func currentFlags() -> CGEventFlags {
            var flags: CGEventFlags = []
            for (index, modifier) in modifiers.enumerated() where down[index] {
                flags.formUnion(modifier.shared.union(modifier.bit))
            }
            return flags
        }
        func feed(_ event: PushToTalkStateMachine.Event?) {
            guard let event, let transition = machine.handle(event) else { return }
            if transition == .startedProcessing {
                _ = machine.handle(.processingFinished)
            }
        }

        for _ in 0..<4_000 {
            let roll = random.next() % 100
            if roll < 3 {
                feed(detector.setKeys(keySets[Int(random.next() % UInt64(keySets.count))]))
            } else if roll < 4 {
                feed(detector.reset())
            } else if roll < 8 {
                feed(detector.cancelForClick())
            } else if roll < 20 {
                let decision = detector.handle(type: .keyDown, keyCode: Self.c, flags: currentFlags())
                #expect(decision.swallow == false)
                feed(decision.event)
            } else {
                let index = Int(random.next() % UInt64(modifiers.count))
                down[index].toggle()
                let modifier = modifiers[index]
                let decision = detector.handle(type: .flagsChanged, keyCode: modifier.keyCode, flags: currentFlags())
                if decision.swallow {
                    #expect(modifier.keyCode == Self.fn, "seed \(seed): swallowed key code \(modifier.keyCode)")
                    if down[index] {
                        fnPressWasSwallowed = true
                    } else {
                        #expect(fnPressWasSwallowed, "seed \(seed): swallowed an fn release without its press")
                        fnPressWasSwallowed = false
                    }
                } else if modifier.keyCode == Self.fn, !down[index] {
                    fnPressWasSwallowed = false
                }
                feed(decision.event)
            }
            if !down.contains(true) {
                #expect(detector.phase == .up, "seed \(seed): \(detector.phase) with every key up")
                #expect(machine.state == .idle, "seed \(seed): \(machine.state) with every key up")
            }
        }
    }

    @Test func rightControlCIsAShortcutNotADictation() {
        let run = transitions(keys: TalkKey.defaultKeys, for: [
            (.flagsChanged, Self.rightControl, [.maskControl, Self.rightControlBit]),
            (.keyDown, Self.c, [.maskControl, Self.rightControlBit]),
            (.flagsChanged, Self.rightControl, []),
        ])
        #expect(run.transitions == [.startedListening, .cancelledListening])
        #expect(run.machine.state == .idle)
    }
}
