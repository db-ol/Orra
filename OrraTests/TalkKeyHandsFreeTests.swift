import CoreGraphics
import Testing
@testable import Orra

/// Taps, double presses, hands free dictations and the delay of the left hand keys, with an
/// explicit clock, so a tap and a hold differ only in the times the test passes.
struct TalkKeyHandsFreeTests {
    typealias Decision = TalkKeyDetector.Decision
    typealias Event = PushToTalkStateMachine.Event

    static let escape: Int64 = 53
    static let c: Int64 = 8
    static let tab: Int64 = 48
    static let shift: Int64 = 56
    static let rightControlFlags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
    static let leftCommandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)

    /// A clock the test moves by hand.
    struct Clock {
        var now = ContinuousClock.now

        mutating func advance(_ duration: Duration) {
            now = now.advanced(by: duration)
        }
    }

    var clock = Clock()

    private func down(_ key: TalkKey, _ detector: inout TalkKeyDetector, with modifiers: CGEventFlags = []) -> Decision {
        let flags = key.downFlag.union(key.sharedFlag ?? []).union(modifiers)
        return detector.handle(type: .flagsChanged, keyCode: key.keyCode, flags: flags, at: clock.now)
    }

    private func up(_ key: TalkKey, _ detector: inout TalkKeyDetector, with modifiers: CGEventFlags = []) -> Decision {
        detector.handle(type: .flagsChanged, keyCode: key.keyCode, flags: modifiers, at: clock.now)
    }

    private func keyDown(_ keyCode: Int64, _ detector: inout TalkKeyDetector, flags: CGEventFlags = []) -> Decision {
        detector.handle(type: .keyDown, keyCode: keyCode, flags: flags, at: clock.now)
    }

    /// The timer the detector asks for fires.
    private func fire(_ detector: inout TalkKeyDetector) -> Event? {
        detector.timerFired(generation: detector.generation)
    }

    /// A tap: down, a short wait, up.
    private mutating func tap(_ key: TalkKey, _ detector: inout TalkKeyDetector) -> [Event] {
        let pressed = down(key, &detector).event
        clock.advance(.milliseconds(80))
        let released = up(key, &detector).event
        clock.advance(.milliseconds(100))
        return [pressed, released].compactMap(\.self)
    }

    /// Starts a hands free dictation of `key` with a double press, and lets the key up.
    private mutating func startHandsFree(_ key: TalkKey, _ detector: inout TalkKeyDetector) -> [Event] {
        var events = tap(key, &detector)
        events += [down(key, &detector).event, up(key, &detector).event].compactMap(\.self)
        return events
    }

    // MARK: Tap and double press

    @Test mutating func aQuickDoublePressStartsHandsFree() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        #expect(down(.rightControl, &detector) == Decision(event: .pressed(isRepeat: false), swallow: false))
        clock.advance(.milliseconds(120))
        #expect(up(.rightControl, &detector) == Decision(event: .tapped, swallow: false))
        #expect(detector.phase == .tapped(.rightControl, recording: true))
        #expect(detector.timer == .doublePressWindow)
        clock.advance(.milliseconds(150))
        #expect(down(.rightControl, &detector) == Decision(event: .doublePressed, swallow: false))
        #expect(detector.phase == .handsFreeKeyDown(.rightControl, finishes: false))
        // The release of the second press does not end the dictation.
        clock.advance(.milliseconds(90))
        #expect(up(.rightControl, &detector) == .passThrough)
        #expect(detector.phase == .handsFree(.rightControl))
        #expect(detector.timer == nil)
        // A later press on its own ends it at its release.
        clock.advance(.seconds(5))
        #expect(down(.rightControl, &detector) == .passThrough)
        clock.advance(.milliseconds(100))
        #expect(up(.rightControl, &detector) == Decision(event: .released, swallow: false))
        #expect(detector.phase == .up)
    }

    @Test mutating func aTapWithoutASecondPressEndsWhenTheWindowCloses() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        #expect(tap(.rightControl, &detector) == [.pressed(isRepeat: false), .tapped])
        #expect(fire(&detector) == .cancelled)
        #expect(detector.phase == .up)
    }

    @Test mutating func aSlowSecondPressIsAHold() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        var machine = PushToTalkStateMachine()
        func feed(_ event: Event?) -> PushToTalkStateMachine.Transition? {
            event.flatMap { machine.handle($0) }
        }
        #expect(feed(down(.rightControl, &detector).event) == .startedListening)
        clock.advance(.milliseconds(100))
        #expect(feed(up(.rightControl, &detector).event) == .awaitingSecondPress)
        // The window closes before the second press.
        clock.advance(TalkKeyDetector.doublePressWindow)
        #expect(feed(fire(&detector)) == .cancelledListening)
        #expect(feed(down(.rightControl, &detector).event) == .startedListening)
        clock.advance(.seconds(2))
        #expect(feed(up(.rightControl, &detector).event) == .startedProcessing)
        #expect(machine.state == .processing)
    }

    @Test mutating func aLongHoldIsNeverATap() {
        var detector = TalkKeyDetector(keys: [.fn])
        #expect(down(.fn, &detector) == Decision(event: .pressed(isRepeat: false), swallow: true))
        clock.advance(TalkKeyDetector.tapLimit)
        #expect(up(.fn, &detector) == Decision(event: .released, swallow: true))
        #expect(detector.phase == .up)
        #expect(detector.timer == nil)
    }

    @Test mutating func aStaleTimerDoesNothing() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = tap(.rightControl, &detector)
        let old = detector.generation
        _ = down(.rightControl, &detector)
        #expect(detector.timerFired(generation: old) == nil)
        #expect(detector.phase == .handsFreeKeyDown(.rightControl, finishes: false))
    }

    @Test mutating func anotherKeyBetweenTheTwoPressesEndsTheWindow() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = tap(.rightControl, &detector)
        #expect(keyDown(Self.c, &detector) == Decision(event: .cancelled, swallow: false))
        #expect(detector.phase == .up)
        // The next press is a new hold.
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
    }

    @Test mutating func aSecondPressWithAnotherModifierIsAShortcut() {
        var detector = TalkKeyDetector(keys: [.fn])
        _ = tap(.fn, &detector)
        #expect(down(.fn, &detector, with: .maskShift) == Decision(event: .cancelled, swallow: false))
        #expect(detector.phase == .passingThrough(.fn))
        #expect(up(.fn, &detector, with: .maskShift) == .passThrough)
    }

    @Test mutating func aClickBetweenTheTwoPressesEndsTheWindow() {
        var detector = TalkKeyDetector(keys: [.fn])
        _ = tap(.fn, &detector)
        #expect(detector.cancelForClick() == .cancelled)
        #expect(detector.phase == .up)
    }

    @Test mutating func turningHandsFreeOffEndsATapsWindow() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = tap(.rightControl, &detector)
        #expect(detector.setHandsFreeEnabled(false) == .cancelled)
        #expect(detector.phase == .up)
        // Now a quick press and release is a hold, which the controller finds too short.
        #expect(tap(.rightControl, &detector) == [.pressed(isRepeat: false), .released])
    }

    @Test mutating func fnStaysHiddenThroughoutHandsFree() {
        var detector = TalkKeyDetector(keys: [.fn])
        #expect(down(.fn, &detector).swallow)
        clock.advance(.milliseconds(50))
        #expect(up(.fn, &detector) == Decision(event: .tapped, swallow: true))
        #expect(down(.fn, &detector) == Decision(event: .doublePressed, swallow: true))
        #expect(up(.fn, &detector) == Decision(event: nil, swallow: true))
        #expect(down(.fn, &detector) == Decision(event: nil, swallow: true))
        #expect(up(.fn, &detector) == Decision(event: .released, swallow: true))
    }

    // MARK: During hands free

    @Test mutating func typingAndClickingLeaveHandsFreeAlone() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        #expect(keyDown(Self.c, &detector) == .passThrough)
        #expect(detector.cancelForClick() == nil)
        let shiftDown = detector.handle(type: .flagsChanged, keyCode: Self.shift, flags: .maskShift, at: clock.now)
        #expect(shiftDown == .passThrough)
        #expect(detector.phase == .handsFree(.rightControl))
    }

    @Test mutating func escapeCancelsHandsFreeAndIsSwallowed() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        #expect(keyDown(Self.escape, &detector) == Decision(event: .cancelled, swallow: true))
        #expect(detector.phase == .up)
        // Afterwards Escape belongs to the app again.
        #expect(keyDown(Self.escape, &detector) == .passThrough)
    }

    @Test mutating func escapeWhileTheKeyIsDownCancelsToo() {
        var detector = TalkKeyDetector(keys: [.fn])
        _ = startHandsFree(.fn, &detector)
        _ = down(.fn, &detector)
        #expect(keyDown(Self.escape, &detector) == Decision(event: .cancelled, swallow: true))
        #expect(detector.phase == .cancelled(.fn))
        // The release finishes nothing and stays hidden, like its press.
        #expect(up(.fn, &detector) == Decision(event: nil, swallow: true))
        #expect(detector.phase == .up)
    }

    @Test(arguments: [TalkKeyDetector.Phase.up, .holding(.rightControl)])
    func escapeOutsideHandsFreeIsNotSwallowed(in phase: TalkKeyDetector.Phase) {
        var detector = TalkKeyDetector(keys: [.rightControl])
        if phase == .holding(.rightControl) {
            _ = detector.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlFlags)
        }
        #expect(detector.phase == phase)
        #expect(detector.handle(type: .keyDown, keyCode: Self.escape, flags: []).swallow == false)
    }

    @Test mutating func aShortcutWithTheKeyDoesNotFinish() {
        var detector = TalkKeyDetector(keys: [.leftCommand])
        _ = startHandsFree(.leftCommand, &detector)
        #expect(detector.phase == .handsFree(.leftCommand))
        // Command+Tab to another app.
        #expect(down(.leftCommand, &detector) == .passThrough)
        #expect(keyDown(Self.tab, &detector, flags: Self.leftCommandFlags) == .passThrough)
        #expect(up(.leftCommand, &detector) == .passThrough)
        #expect(detector.phase == .handsFree(.leftCommand))
        // A press of its own then finishes.
        _ = down(.leftCommand, &detector)
        #expect(up(.leftCommand, &detector).event == .released)
    }

    @Test mutating func theKeyWithAnotherModifierDoesNotFinish() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        _ = down(.rightControl, &detector, with: .maskShift)
        #expect(up(.rightControl, &detector, with: .maskShift) == .passThrough)
        #expect(detector.phase == .handsFree(.rightControl))
    }

    @Test mutating func aControlClickDoesNotFinishButAnFnClickDoes() {
        var control = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &control)
        _ = down(.rightControl, &control)
        #expect(control.cancelForClick() == nil)
        #expect(up(.rightControl, &control).event == nil)
        #expect(control.phase == .handsFree(.rightControl))

        var fn = TalkKeyDetector(keys: [.fn])
        _ = startHandsFree(.fn, &fn)
        _ = down(.fn, &fn)
        #expect(fn.cancelForClick() == nil)
        #expect(up(.fn, &fn).event == .released)
    }

    @Test mutating func changingTheKeysDuringHandsFreeCancelsIt() {
        var detector = TalkKeyDetector(keys: [.rightControl, .fn])
        _ = startHandsFree(.rightControl, &detector)
        // Keeping the key changes nothing.
        #expect(detector.setKeys([.rightControl]) == nil)
        #expect(detector.phase == .handsFree(.rightControl))
        #expect(detector.setKeys([.fn]) == .cancelled)
        #expect(detector.phase == .up)
        #expect(keyDown(Self.escape, &detector) == .passThrough)
    }

    @Test mutating func theOwnerEndsHandsFree() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        detector.endHandsFree()
        #expect(detector.phase == .up)
        #expect(keyDown(Self.escape, &detector) == .passThrough)

        // Ended while the key is down, its release finishes nothing.
        _ = startHandsFree(.rightControl, &detector)
        _ = down(.rightControl, &detector)
        detector.endHandsFree()
        #expect(up(.rightControl, &detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test mutating func resetDuringHandsFreeCancels() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        #expect(detector.reset() == .cancelled)
        #expect(detector.phase == .up)
    }

    // MARK: Left hand keys

    @Test mutating func aLeftKeyRecordsOnlyAfterItsDelay() {
        var detector = TalkKeyDetector(keys: [.leftCommand])
        #expect(down(.leftCommand, &detector) == .passThrough)
        #expect(detector.phase == .arming(.leftCommand))
        #expect(detector.timer == .leftKeyDelay)
        clock.advance(TalkKeyDetector.leftKeyDelay)
        #expect(fire(&detector) == .pressed(isRepeat: false))
        #expect(detector.phase == .holding(.leftCommand))
        clock.advance(.seconds(2))
        #expect(up(.leftCommand, &detector) == Decision(event: .released, swallow: false))
    }

    @Test mutating func aLeftKeyShortcutIsSilent() {
        var detector = TalkKeyDetector(keys: [.leftCommand])
        _ = down(.leftCommand, &detector)
        // Command+C before the delay: nothing recorded, every event passes through.
        #expect(keyDown(Self.c, &detector, flags: Self.leftCommandFlags) == .passThrough)
        #expect(detector.phase == .passingThrough(.leftCommand))
        #expect(detector.timer == nil)
        #expect(up(.leftCommand, &detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test mutating func aClickWithALeftKeyIsSilent() {
        var detector = TalkKeyDetector(keys: [.leftControl])
        _ = down(.leftControl, &detector)
        #expect(detector.cancelForClick() == nil)
        #expect(detector.phase == .passingThrough(.leftControl))
        #expect(up(.leftControl, &detector) == .passThrough)
    }

    @Test mutating func anotherModifierWithALeftKeyIsSilent() {
        var detector = TalkKeyDetector(keys: [.leftOption])
        _ = down(.leftOption, &detector)
        let shiftDown = detector.handle(type: .flagsChanged, keyCode: Self.shift, flags: [.maskShift, .maskAlternate, TalkKey.leftOption.downFlag], at: clock.now)
        #expect(shiftDown == .passThrough)
        #expect(detector.phase == .passingThrough(.leftOption))
    }

    @Test mutating func aLeftKeyDoublePressStartsHandsFreeWithoutRecordingTheTap() {
        var detector = TalkKeyDetector(keys: [.leftCommand])
        var machine = PushToTalkStateMachine()
        var transitions: [PushToTalkStateMachine.Transition] = []
        for event in startHandsFree(.leftCommand, &detector) {
            if let transition = machine.handle(event) {
                transitions.append(transition)
            }
        }
        #expect(transitions == [.startedHandsFree])
        #expect(machine.state == .handsFree)
        #expect(detector.phase == .handsFree(.leftCommand))
    }

    @Test mutating func aLeftKeyTapWithoutASecondPressSendsNothing() {
        var detector = TalkKeyDetector(keys: [.leftCommand])
        #expect(tap(.leftCommand, &detector) == [])
        #expect(detector.phase == .tapped(.leftCommand, recording: false))
        #expect(fire(&detector) == nil)
        #expect(detector.phase == .up)
    }

    @Test mutating func withHandsFreeOffALeftKeyTapLeavesNothing() {
        var detector = TalkKeyDetector(keys: [.leftCommand], handsFreeEnabled: false)
        #expect(tap(.leftCommand, &detector) == [])
        #expect(detector.phase == .up)
        #expect(detector.timer == nil)
    }

    @Test mutating func aLeftKeyIsToldFromItsRightTwin() {
        var detector = TalkKeyDetector(keys: [.leftControl])
        // Right Control is not a talk key here.
        let rightDown = detector.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlFlags, at: clock.now)
        #expect(rightDown == .passThrough)
        #expect(detector.phase == .up)
        // Left Control while right Control is down belongs to a shortcut.
        #expect(down(.leftControl, &detector, with: Self.rightControlFlags) == .passThrough)
        #expect(detector.phase == .passingThrough(.leftControl))
    }

    // MARK: Random sequences

    /// Plays thousands of random presses of eight modifiers with hands free on, with key
    /// downs, Escape, clicks, timers, changes of talk keys and resets mixed in, and the time
    /// moving on by random steps. The detector and the state model follow each other the
    /// way HotkeyTap and PushToTalkController do. Checks what must always hold: only fn's own
    /// events and Escape during hands free are swallowed, the detector holds a hands free
    /// dictation exactly while the state model does, and once every key is up nothing
    /// records except a tap waiting for its second press or a hands free dictation.
    @Test(arguments: [11, 12, 13, 14, 15, 16, 17, 18] as [UInt64])
    func randomSequencesKeepTheRules(seed: UInt64) {
        struct Modifier {
            let keyCode: Int64
            let shared: CGEventFlags
            let bit: CGEventFlags
        }
        let modifiers = [
            Modifier(keyCode: 63, shared: .maskSecondaryFn, bit: []),
            Modifier(keyCode: 59, shared: .maskControl, bit: CGEventFlags(rawValue: 0x01)),
            Modifier(keyCode: 62, shared: .maskControl, bit: CGEventFlags(rawValue: 0x2000)),
            Modifier(keyCode: 58, shared: .maskAlternate, bit: CGEventFlags(rawValue: 0x20)),
            Modifier(keyCode: 61, shared: .maskAlternate, bit: CGEventFlags(rawValue: 0x40)),
            Modifier(keyCode: 55, shared: .maskCommand, bit: CGEventFlags(rawValue: 0x08)),
            Modifier(keyCode: 54, shared: .maskCommand, bit: CGEventFlags(rawValue: 0x10)),
            Modifier(keyCode: Self.shift, shared: .maskShift, bit: CGEventFlags(rawValue: 0x02)),
        ]
        let keySets: [Set<TalkKey>] = [[.rightControl], [.fn], [.leftCommand], [.rightControl, .fn], [.leftControl, .rightOption], Set(TalkKey.allCases)]
        var random = TalkKeyDetectorTests.SplitMix(state: seed)
        var down = Array(repeating: false, count: modifiers.count)
        var detector = TalkKeyDetector(keys: keySets[Int(seed) % keySets.count])
        var machine = PushToTalkStateMachine()
        var now = ContinuousClock.now

        func currentFlags() -> CGEventFlags {
            var flags: CGEventFlags = []
            for (index, modifier) in modifiers.enumerated() where down[index] {
                flags.formUnion(modifier.shared.union(modifier.bit))
            }
            return flags
        }
        func feed(_ event: Event?) {
            if let event, let transition = machine.handle(event), transition == .startedProcessing {
                _ = machine.handle(.processingFinished)
            }
            if machine.state != .handsFree {
                detector.endHandsFree()
            }
        }

        for _ in 0..<4_000 {
            now = now.advanced(by: .milliseconds(Int(random.next() % 250)))
            let roll = random.next() % 100
            if roll < 2 {
                feed(detector.setKeys(keySets[Int(random.next() % UInt64(keySets.count))]))
            } else if roll < 3 {
                feed(detector.reset())
            } else if roll < 7 {
                feed(detector.cancelForClick())
            } else if roll < 15 {
                feed(detector.timerFired(generation: detector.generation))
            } else if roll < 20 {
                let wasHandsFree = detector.phase.isHandsFree
                let decision = detector.handle(type: .keyDown, keyCode: Self.escape, flags: currentFlags(), at: now)
                #expect(decision.swallow == wasHandsFree, "seed \(seed): Escape swallowed \(decision.swallow)")
                feed(decision.event)
            } else if roll < 28 {
                let decision = detector.handle(type: .keyDown, keyCode: Self.c, flags: currentFlags(), at: now)
                #expect(decision.swallow == false)
                feed(decision.event)
            } else {
                let index = Int(random.next() % UInt64(modifiers.count))
                down[index].toggle()
                let modifier = modifiers[index]
                let decision = detector.handle(type: .flagsChanged, keyCode: modifier.keyCode, flags: currentFlags(), at: now)
                if decision.swallow {
                    #expect(modifier.keyCode == 63, "seed \(seed): swallowed key code \(modifier.keyCode)")
                }
                feed(decision.event)
            }
            #expect(detector.phase.isHandsFree == (machine.state == .handsFree), "seed \(seed): \(detector.phase) with \(machine.state)")
            if !down.contains(true) {
                switch detector.phase {
                case .up:
                    #expect(machine.state == .idle, "seed \(seed): \(machine.state) with every key up")
                case .tapped:
                    #expect(machine.state == .idle || machine.state == .waitingForSecondPress, "seed \(seed): \(machine.state) after a tap")
                case .handsFree:
                    #expect(machine.state == .handsFree)
                default:
                    Issue.record("seed \(seed): \(detector.phase) with every key up")
                }
            }
        }
    }
}
