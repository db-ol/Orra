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
    static let e: Int64 = 14
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
        // The second press goes on with the tap's recording. Only its release tells.
        #expect(down(.rightControl, &detector) == Decision(event: .pressed(isRepeat: false), swallow: false))
        #expect(detector.phase == .holding(.rightControl))
        #expect(detector.timer == nil)
        // Its quick release starts the hands free dictation.
        clock.advance(.milliseconds(90))
        #expect(up(.rightControl, &detector) == Decision(event: .doublePressed, swallow: false))
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
        #expect(detector.phase == .holding(.rightControl))
    }

    @Test mutating func aTapThenAHoldIsAHold() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        var machine = PushToTalkStateMachine()
        func feed(_ event: Event?) -> PushToTalkStateMachine.Transition? {
            event.flatMap { machine.handle($0) }
        }
        #expect(feed(down(.rightControl, &detector).event) == .startedListening)
        clock.advance(.milliseconds(60))
        #expect(feed(up(.rightControl, &detector).event) == .awaitingSecondPress)
        clock.advance(.milliseconds(200))
        #expect(feed(down(.rightControl, &detector).event) == .resumedListening)
        // Held to dictate a sentence. Its release pastes, nothing goes on recording.
        clock.advance(.seconds(3))
        #expect(feed(up(.rightControl, &detector).event) == .startedProcessing)
        #expect(detector.phase == .up)
        #expect(machine.state == .processing)
    }

    @Test mutating func aLeftKeyTapThenAHoldIsAHold() {
        var detector = TalkKeyDetector(keys: [.leftCommand])
        #expect(tap(.leftCommand, &detector) == [])
        #expect(down(.leftCommand, &detector) == .passThrough)
        #expect(detector.phase == .arming(.leftCommand))
        clock.advance(TalkKeyDetector.leftKeyDelay)
        #expect(fire(&detector) == .pressed(isRepeat: false))
        clock.advance(.seconds(2))
        #expect(up(.leftCommand, &detector) == Decision(event: .released, swallow: false))
        #expect(detector.phase == .up)
    }

    @Test mutating func aShortcutOnTheSecondPressOfALeftKeyIsSilent() {
        var detector = TalkKeyDetector(keys: [.leftCommand])
        _ = tap(.leftCommand, &detector)
        // Command, then Command+V within the window: no recording and no cue.
        #expect(down(.leftCommand, &detector) == .passThrough)
        #expect(keyDown(9, &detector, flags: Self.leftCommandFlags) == .passThrough)
        #expect(detector.phase == .passingThrough(.leftCommand))
        #expect(detector.timer == nil)
        #expect(up(.leftCommand, &detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test mutating func aShortcutOnTheSecondPressOfARightKeyCancels() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = tap(.rightControl, &detector)
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
        // Right Control+C: the tap's recording is discarded, nothing goes hands free.
        #expect(keyDown(Self.c, &detector, flags: Self.rightControlFlags) == Decision(event: .cancelled, swallow: false))
        #expect(up(.rightControl, &detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test mutating func aClickOnTheSecondPressIsAShortcut() {
        var command = TalkKeyDetector(keys: [.leftCommand])
        _ = tap(.leftCommand, &command)
        _ = down(.leftCommand, &command)
        #expect(command.cancelForClick() == nil)
        #expect(up(.leftCommand, &command) == .passThrough)
        #expect(command.phase == .up)

        var control = TalkKeyDetector(keys: [.rightControl])
        _ = tap(.rightControl, &control)
        _ = down(.rightControl, &control)
        #expect(control.cancelForClick() == .cancelled)
        #expect(up(.rightControl, &control).event == nil)
        #expect(control.phase == .up)
    }

    @Test mutating func anotherTalkKeyInTheWindowStartsItsOwnHold() {
        var detector = TalkKeyDetector(keys: [.fn, .rightControl])
        var machine = PushToTalkStateMachine()
        func feed(_ event: Event?) -> PushToTalkStateMachine.Transition? {
            event.flatMap { machine.handle($0) }
        }
        for event in tap(.fn, &detector) {
            _ = feed(event)
        }
        #expect(machine.state == .waitingForSecondPress)
        #expect(feed(down(.rightControl, &detector).event) == .resumedListening)
        #expect(detector.phase == .holding(.rightControl))
        clock.advance(.seconds(2))
        #expect(feed(up(.rightControl, &detector).event) == .startedProcessing)
    }

    @Test mutating func anotherLeftTalkKeyInTheWindowDiscardsTheTap() {
        var detector = TalkKeyDetector(keys: [.fn, .leftOption])
        _ = tap(.fn, &detector)
        // The left key records nothing yet, so the tap's recording ends.
        #expect(down(.leftOption, &detector) == Decision(event: .cancelled, swallow: false))
        #expect(detector.phase == .arming(.leftOption))
        clock.advance(TalkKeyDetector.leftKeyDelay)
        #expect(fire(&detector) == .pressed(isRepeat: false))
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
        #expect(down(.fn, &detector) == Decision(event: .pressed(isRepeat: false), swallow: true))
        #expect(up(.fn, &detector) == Decision(event: .doublePressed, swallow: true))
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

    // MARK: After a stop at the recording limit

    /// In Hold mode the quick press meant to finish a hands free dictation the limit stopped
    /// only tells at its release, and drops the capture it started. The press after it
    /// records as usual.
    @Test mutating func afterAStopAtTheLimitThePressMeantToStopOnlyTells() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        #expect(detector.stopAtLimit() == true)
        #expect(detector.phase == .up)
        #expect(detector.limitKey == .rightControl)
        // Escape and typing pass through.
        #expect(keyDown(Self.escape, &detector) == .passThrough)
        #expect(keyDown(Self.c, &detector) == .passThrough)
        clock.advance(.seconds(5))
        // Right Control records at once, so it captures early while it waits.
        #expect(down(.rightControl, &detector) == Decision(event: .armed, swallow: false))
        #expect(detector.phase == .arming(.rightControl))
        #expect(detector.timer == .leftKeyDelay)
        clock.advance(.milliseconds(120))
        #expect(up(.rightControl, &detector) == Decision(event: .pressedAfterLimit, swallow: false))
        #expect(detector.limitKey == nil)
        #expect(detector.phase == .tapped(.rightControl, recording: false))
        #expect(fire(&detector) == nil)
        #expect(down(.rightControl, &detector) == Decision(event: .pressed(isRepeat: false), swallow: false))
    }

    /// In Hold mode, holding the key is how one dictates, so a press held past the wait is a
    /// hold that keeps its early capture, and the wait is over.
    @Test mutating func inHoldModeAPressHeldPastTheWaitIsAHold() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        _ = detector.stopAtLimit()
        #expect(down(.rightControl, &detector).event == .armed)
        clock.advance(TalkKeyDetector.leftKeyDelay)
        #expect(fire(&detector) == .pressed(isRepeat: false))
        #expect(detector.phase == .holding(.rightControl))
        #expect(detector.limitKey == nil)
        clock.advance(.seconds(3))
        #expect(up(.rightControl, &detector).event == .released)
    }

    /// A left hand key waits as it always does, and records nothing before its delay.
    @Test mutating func inHoldModeALeftKeyWaitsAsUsual() {
        var detector = TalkKeyDetector(keys: [.leftCommand])
        _ = startHandsFree(.leftCommand, &detector)
        _ = detector.stopAtLimit()
        #expect(down(.leftCommand, &detector) == .passThrough)
        clock.advance(.milliseconds(120))
        #expect(up(.leftCommand, &detector).event == .pressedAfterLimit)
        clock.advance(TalkKeyDetector.doublePressWindow)
        _ = fire(&detector)
        #expect(down(.leftCommand, &detector) == .passThrough)
        #expect(fire(&detector) == .pressed(isRepeat: false))
    }

    /// The press meant to stop does not use up a double press: a quick second press starts
    /// hands free as usual.
    @Test mutating func inHoldModeADoublePressAfterTheLimitStartsHandsFree() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        _ = detector.stopAtLimit()
        #expect(tap(.rightControl, &detector) == [.armed, .pressedAfterLimit])
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
        clock.advance(.milliseconds(90))
        #expect(up(.rightControl, &detector).event == .doublePressed)
        #expect(detector.phase == .handsFree(.rightControl))
    }

    /// In Double press, the single press that finishes a dictation is the one that tells,
    /// however long it is, and it records nothing.
    @Test mutating func inDoublePressASinglePressTells() {
        var detector = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .doubleTap])
        #expect(startHandsFree(.rightControl, &detector) == [.doublePressed])
        #expect(detector.stopAtLimit() == true)
        #expect(down(.rightControl, &detector) == .passThrough)
        #expect(detector.timer == nil)
        clock.advance(.seconds(2))
        #expect(up(.rightControl, &detector).event == .pressedAfterLimit)
        #expect(detector.phase == .up)
        #expect(detector.limitKey == nil)
    }

    /// In Press to start and stop, a first press still down when the limit stops the
    /// recording is not the press meant to stop it, so the next one is, however long.
    @Test mutating func inPressToStartAndStopAFirstPressStillDownWaitsForTheNext() {
        var detector = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .toggle])
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
        #expect(detector.stopAtLimit() == true)
        clock.advance(.seconds(1))
        #expect(up(.rightControl, &detector) == .passThrough)
        #expect(detector.phase == .up)
        #expect(detector.limitKey == .rightControl)
        #expect(down(.rightControl, &detector) == .passThrough)
        clock.advance(.seconds(2))
        #expect(up(.rightControl, &detector).event == .pressedAfterLimit)
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
    }

    /// A press under way when the limit stops a hands free dictation is the press that was
    /// meant to stop it.
    @Test mutating func aPressUnderWayAtTheLimitTells() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        _ = down(.rightControl, &detector)
        #expect(detector.stopAtLimit() == true)
        clock.advance(.seconds(1))
        #expect(up(.rightControl, &detector).event == .pressedAfterLimit)
        #expect(detector.phase == .up)
        #expect(detector.limitKey == nil)
    }

    /// fn's events stay hidden, as during the dictation.
    @Test mutating func afterAStopAtTheLimitFnStaysHidden() {
        var detector = TalkKeyDetector(keys: [.fn])
        _ = startHandsFree(.fn, &detector)
        #expect(detector.stopAtLimit() == true)
        #expect(down(.fn, &detector) == Decision(event: .armed, swallow: true))
        #expect(up(.fn, &detector) == Decision(event: .pressedAfterLimit, swallow: true))

        var toggle = TalkKeyDetector(keys: [.fn], modes: [.fn: .toggle])
        _ = down(.fn, &toggle)
        _ = up(.fn, &toggle)
        #expect(toggle.stopAtLimit() == true)
        #expect(down(.fn, &toggle) == Decision(event: nil, swallow: true))
        #expect(up(.fn, &toggle) == Decision(event: .pressedAfterLimit, swallow: true))
    }

    /// A shortcut with the key, such as Control C, or a Control click, tells nothing and the
    /// wait goes on. In Hold mode it drops the early capture, as for any key that waits.
    @Test mutating func aShortcutAfterAStopAtTheLimitKeepsWaiting() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        _ = detector.stopAtLimit()
        #expect(down(.rightControl, &detector).event == .armed)
        #expect(keyDown(Self.c, &detector, flags: Self.rightControlFlags) == Decision(event: .cancelled, swallow: false))
        #expect(up(.rightControl, &detector) == .passThrough)
        #expect(detector.phase == .up)
        #expect(detector.limitKey == .rightControl)
        #expect(down(.rightControl, &detector).event == .armed)
        #expect(detector.cancelForClick() == .cancelled)
        #expect(up(.rightControl, &detector) == .passThrough)
        #expect(detector.limitKey == .rightControl)
        #expect(down(.rightControl, &detector).event == .armed)
        #expect(up(.rightControl, &detector).event == .pressedAfterLimit)

        var toggle = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .toggle])
        _ = down(.rightControl, &toggle)
        _ = up(.rightControl, &toggle)
        _ = toggle.stopAtLimit()
        _ = down(.rightControl, &toggle)
        #expect(keyDown(Self.c, &toggle, flags: Self.rightControlFlags) == .passThrough)
        #expect(up(.rightControl, &toggle) == .passThrough)
        #expect(toggle.limitKey == .rightControl)
        _ = down(.rightControl, &toggle)
        #expect(toggle.cancelForClick() == nil)
        #expect(up(.rightControl, &toggle) == .passThrough)
        #expect(toggle.limitKey == .rightControl)
        _ = down(.rightControl, &toggle)
        #expect(up(.rightControl, &toggle).event == .pressedAfterLimit)
    }

    /// A hold in Hold mode finishes nothing at its release, so it stays as it is.
    @Test mutating func aHoldInHoldModeIsLeftAlone() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = down(.rightControl, &detector)
        #expect(detector.stopAtLimit() == false)
        #expect(detector.phase == .holding(.rightControl))
        #expect(detector.limitKey == nil)
        clock.advance(.seconds(1))
        #expect(up(.rightControl, &detector).event == .released)
    }

    @Test mutating func theOwnerEndsTheWait() {
        var detector = TalkKeyDetector(keys: [.rightControl])
        _ = startHandsFree(.rightControl, &detector)
        _ = detector.stopAtLimit()
        detector.endLimitWindow()
        #expect(detector.phase == .up)
        #expect(detector.limitKey == nil)
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
        clock.advance(.seconds(1))
        _ = up(.rightControl, &detector)

        // Ended while a press in Hold mode waits, the press ends like any other: a quick
        // one is a tap that drops its capture.
        _ = startHandsFree(.rightControl, &detector)
        _ = detector.stopAtLimit()
        #expect(down(.rightControl, &detector).event == .armed)
        detector.endLimitWindow()
        clock.advance(.milliseconds(80))
        #expect(up(.rightControl, &detector) == Decision(event: .cancelled, swallow: false))

        // Ended while the key is down in Press to start and stop, its release tells nothing.
        var toggle = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .toggle])
        _ = down(.rightControl, &toggle)
        _ = toggle.stopAtLimit()
        toggle.endLimitWindow()
        #expect(up(.rightControl, &toggle) == .passThrough)
        #expect(toggle.phase == .up)
        #expect(down(.rightControl, &toggle).event == .pressed(isRepeat: false))
    }

    /// Another talk key presses as usual, and the owner ends the wait once its dictation
    /// starts. A shortcut with it, here left Command Tab, leaves the wait as it is.
    @Test mutating func anotherTalkKeyPressesAsUsual() {
        var detector = TalkKeyDetector(keys: [.rightControl, .fn])
        _ = startHandsFree(.rightControl, &detector)
        _ = detector.stopAtLimit()
        #expect(down(.fn, &detector) == Decision(event: .pressed(isRepeat: false), swallow: true))
        #expect(detector.phase == .holding(.fn))
        #expect(detector.limitKey == .rightControl)

        var withLeftKey = TalkKeyDetector(keys: [.rightControl, .leftCommand])
        _ = startHandsFree(.rightControl, &withLeftKey)
        _ = withLeftKey.stopAtLimit()
        #expect(down(.leftCommand, &withLeftKey) == .passThrough)
        #expect(keyDown(Self.tab, &withLeftKey, flags: Self.leftCommandFlags) == .passThrough)
        #expect(up(.leftCommand, &withLeftKey) == .passThrough)
        #expect(withLeftKey.phase == .up)
        #expect(withLeftKey.limitKey == .rightControl)
        clock.advance(.seconds(1))
        _ = down(.rightControl, &withLeftKey)
        #expect(up(.rightControl, &withLeftKey).event == .pressedAfterLimit)
    }

    @Test mutating func aChangeOfKeysOrAResetEndsTheWaitSilently() {
        var detector = TalkKeyDetector(keys: [.rightControl, .fn])
        _ = startHandsFree(.rightControl, &detector)
        _ = detector.stopAtLimit()
        #expect(detector.setKeys([.rightControl, .fn], modes: [.rightControl: .toggle]) == nil)
        #expect(detector.limitKey == .rightControl)
        #expect(detector.setKeys([.fn]) == nil)
        #expect(detector.phase == .up)
        #expect(detector.limitKey == nil)
        _ = startHandsFree(.fn, &detector)
        _ = detector.stopAtLimit()
        #expect(detector.reset() == nil)
        #expect(detector.phase == .up)
        #expect(detector.limitKey == nil)
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

    // MARK: Keys that wait on the right hand side

    /// The translation key waits like a left hand key, so right Option still types its
    /// characters and works in shortcuts, while the talk key next to it starts at once. It
    /// starts the microphone at its key down, silently, and its press counts after the wait.
    @Test mutating func aDelayedRightKeyCapturesEarlyAndCountsAfterTheDelay() {
        var detector = TalkKeyDetector(keys: [.rightControl, .rightOption], delayedKeys: [.rightOption])
        #expect(detector.waitsBeforeRecording(.rightOption))
        #expect(detector.capturesEarly(.rightOption))
        #expect(detector.waitsBeforeRecording(.rightControl) == false)
        #expect(detector.capturesEarly(.rightControl) == false)
        let pressed = clock.now
        #expect(down(.rightOption, &detector) == Decision(event: .armed, swallow: false))
        #expect(detector.phase == .arming(.rightOption))
        #expect(detector.timer == .leftKeyDelay)
        #expect(TalkKeyDetector.leftKeyDelay == .milliseconds(300))
        #expect(detector.pressedAt == pressed)
        #expect(detector.pressWaited)
        clock.advance(TalkKeyDetector.leftKeyDelay)
        #expect(fire(&detector) == .pressed(isRepeat: false))
        #expect(detector.phase == .holding(.rightOption))
        // The press is still timed from its key down.
        #expect(detector.pressedAt == pressed)
        clock.advance(.seconds(2))
        #expect(up(.rightOption, &detector) == Decision(event: .released, swallow: false))
        // The talk key does not wait.
        clock.advance(.seconds(1))
        #expect(down(.rightControl, &detector) == Decision(event: .pressed(isRepeat: false), swallow: false))
        #expect(detector.pressWaited == false)
        #expect(detector.pressedAt == clock.now)
    }

    /// A shortcut during the wait, or a press that ends before it, drops the early capture
    /// silently, and every event passes through.
    @Test mutating func anOptionShortcutDuringTheWaitDropsTheEarlyCapture() {
        var detector = TalkKeyDetector(keys: [.rightControl, .rightOption], delayedKeys: [.rightOption])
        let optionFlags = TalkKey.rightOption.downFlag.union(.maskAlternate)
        #expect(down(.rightOption, &detector).event == .armed)
        clock.advance(.milliseconds(120))
        // Option E types an accent: the capture is dropped and every event passes through.
        #expect(keyDown(Self.e, &detector, flags: optionFlags) == Decision(event: .cancelled, swallow: false))
        #expect(detector.phase == .passingThrough(.rightOption))
        #expect(detector.timer == nil)
        clock.advance(.milliseconds(400))
        #expect(up(.rightOption, &detector) == .passThrough)
        #expect(detector.phase == .up)
        // Option with another modifier and a click during the wait drop it too.
        #expect(down(.rightOption, &detector).event == .armed)
        #expect(detector.handle(type: .flagsChanged, keyCode: Self.shift, flags: optionFlags.union(.maskShift), at: clock.now) == Decision(event: .cancelled, swallow: false))
        #expect(detector.phase == .passingThrough(.rightOption))
        _ = up(.rightOption, &detector, with: .maskShift)
        #expect(down(.rightOption, &detector).event == .armed)
        #expect(detector.cancelForClick() == .cancelled)
        #expect(detector.phase == .passingThrough(.rightOption))
        _ = up(.rightOption, &detector)
        // So does a reset, such as a change of keys.
        #expect(down(.rightOption, &detector).event == .armed)
        #expect(detector.reset() == .cancelled)
        #expect(detector.phase == .up)
    }

    @Test mutating func aShortcutAfterTheWaitCancelsTheRecording() {
        var detector = TalkKeyDetector(keys: [.rightOption], delayedKeys: [.rightOption])
        #expect(down(.rightOption, &detector).event == .armed)
        clock.advance(TalkKeyDetector.leftKeyDelay)
        #expect(fire(&detector) == .pressed(isRepeat: false))
        #expect(keyDown(Self.e, &detector, flags: TalkKey.rightOption.downFlag.union(.maskAlternate)) == Decision(event: .cancelled, swallow: false))
    }

    @Test mutating func aDoublePressOfTheTranslationKeyStartsHandsFree() {
        var detector = TalkKeyDetector(keys: [.rightControl, .rightOption], delayedKeys: [.rightOption])
        var machine = PushToTalkStateMachine()
        var transitions: [PushToTalkStateMachine.Transition] = []
        for event in startHandsFree(.rightOption, &detector) {
            if let transition = machine.handle(event) {
                transitions.append(transition)
            }
        }
        // The tap's early capture is dropped at its release. The second press's is kept and
        // becomes the hands free dictation.
        #expect(transitions == [.startedArming, .droppedArming, .startedArming, .confirmedArming])
        #expect(detector.phase == .handsFree(.rightOption))
        // The talk key does not end it, the translation key does.
        clock.advance(.seconds(3))
        _ = down(.rightControl, &detector)
        #expect(up(.rightControl, &detector).event == nil)
        #expect(detector.phase == .handsFree(.rightOption))
        _ = down(.rightOption, &detector)
        clock.advance(.milliseconds(100))
        #expect(up(.rightOption, &detector) == Decision(event: .released, swallow: false))
    }

    @Test mutating func withHandsFreeOffADelayedKeyTapLeavesNothing() {
        var detector = TalkKeyDetector(keys: [.rightOption], delayedKeys: [.rightOption], handsFreeEnabled: false)
        #expect(tap(.rightOption, &detector) == [.armed, .cancelled])
        #expect(detector.phase == .up)
        #expect(detector.timer == nil)
    }

    /// A tap of the talk key, then the translation key within the window: the tap's
    /// recording is dropped, and the translation key records after its own wait.
    @Test mutating func theTranslationKeyAfterATalkKeyTapStartsItsOwnRecording() {
        var detector = TalkKeyDetector(keys: [.rightControl, .rightOption], delayedKeys: [.rightOption])
        var machine = PushToTalkStateMachine()
        var transitions: [PushToTalkStateMachine.Transition] = []
        func feed(_ event: Event?) {
            if let event, let transition = machine.handle(event) {
                transitions.append(transition)
            }
        }
        feed(down(.rightControl, &detector).event)
        clock.advance(.milliseconds(80))
        feed(up(.rightControl, &detector).event)
        clock.advance(.milliseconds(100))
        // One event cannot drop the tap's recording and start another, so the translation
        // key waits without an early capture this time.
        let optionDown = down(.rightOption, &detector)
        #expect(optionDown.event == .cancelled)
        feed(optionDown.event)
        #expect(detector.phase == .arming(.rightOption))
        clock.advance(TalkKeyDetector.leftKeyDelay)
        feed(fire(&detector))
        #expect(detector.phase == .holding(.rightOption))
        #expect(transitions == [.startedListening, .awaitingSecondPress, .cancelledListening, .startedListening])
    }

    /// Only a right hand key or fn that waits captures early. A left hand key or a
    /// combination of modifiers is part of too many shortcuts, a key that does not wait has
    /// no need, and a press in double press mode records nothing.
    @Test mutating func onlyRightHandKeysAndFnThatWaitCaptureEarly() {
        let controlOption = Hotkey.combination(KeyCombination(modifiers: [.control, .option]))
        var detector = TalkKeyDetector(
            keys: [.rightOption, .fn, .leftCommand, .rightControl, controlOption],
            delayedKeys: [.rightOption, .fn, .leftCommand, controlOption]
        )
        #expect(detector.capturesEarly(.rightOption))
        #expect(detector.capturesEarly(.fn))
        #expect(detector.capturesEarly(.leftCommand) == false)
        #expect(detector.capturesEarly(controlOption) == false)
        #expect(detector.capturesEarly(.rightControl) == false)
        #expect(down(.leftCommand, &detector) == .passThrough)
        #expect(detector.phase == .arming(.leftCommand))
        #expect(detector.pressWaited)
        // A left hand shortcut stays silent, as before.
        #expect(keyDown(Self.c, &detector, flags: Self.leftCommandFlags) == .passThrough)
        _ = up(.leftCommand, &detector)
        let doubleTap = TalkKeyDetector(keys: [.rightOption], delayedKeys: [.rightOption], modes: [.rightOption: .doubleTap])
        #expect(doubleTap.capturesEarly(.rightOption) == false)
    }

    /// Press to start and stop, released before the wait is over, starts hands free with
    /// the recording from the key down.
    @Test mutating func aPressToStartReleasedDuringTheWaitKeepsTheEarlyCapture() {
        var detector = TalkKeyDetector(keys: [.rightOption], delayedKeys: [.rightOption], modes: [.rightOption: .toggle])
        var machine = PushToTalkStateMachine()
        var transitions: [PushToTalkStateMachine.Transition] = []
        func feed(_ event: Event?) {
            if let event, let transition = machine.handle(event) {
                transitions.append(transition)
            }
        }
        feed(down(.rightOption, &detector).event)
        clock.advance(.milliseconds(100))
        feed(up(.rightOption, &detector).event)
        #expect(detector.phase == .handsFree(.rightOption))
        #expect(transitions == [.startedArming, .confirmedArming])
        #expect(machine.state == .handsFree)
    }

    /// A change to double press mode during the wait, after which a hold records nothing,
    /// drops the early capture when the tap's limit passes.
    @Test mutating func aModeChangedDuringTheWaitDropsTheEarlyCapture() {
        var detector = TalkKeyDetector(keys: [.rightOption], delayedKeys: [.rightOption])
        #expect(down(.rightOption, &detector).event == .armed)
        #expect(detector.setKeys([.rightOption], delayedKeys: [.rightOption], modes: [.rightOption: .doubleTap]) == nil)
        #expect(detector.timer == .tapLimit)
        clock.advance(TalkKeyDetector.tapLimit)
        #expect(fire(&detector) == .cancelled)
        #expect(detector.phase == .cancelled(.rightOption))
    }

    /// Right Control waits as a modifier of the watched combination Control and Option.
    /// When the combination counts at once, as a talk key does, it keeps the capture that
    /// right Control started.
    @Test mutating func aCombinationThatCountsAtOnceKeepsTheEarlyCapture() {
        let controlOption = Hotkey.combination(KeyCombination(modifiers: [.control, .option]))
        var detector = TalkKeyDetector(keys: [.rightControl, controlOption], delayedKeys: [.rightControl])
        var machine = PushToTalkStateMachine()
        let rightControlDown = down(.rightControl, &detector)
        #expect(rightControlDown.event == .armed)
        _ = machine.handle(.armed)
        clock.advance(.milliseconds(60))
        let optionFlags = Self.rightControlFlags.union(.maskAlternate).union(TalkKey.leftOption.downFlag)
        let optionDown = detector.handle(type: .flagsChanged, keyCode: TalkKey.leftOption.keyCode, flags: optionFlags, at: clock.now)
        #expect(optionDown.event == .pressed(isRepeat: false))
        #expect(detector.phase == .holding(controlOption))
        #expect(machine.handle(.pressed(isRepeat: false)) == .confirmedArming)
        #expect(machine.state == .listening)
    }

    @Test func changingTheDelayedKeysKeepsAPressUnderWay() {
        var detector = TalkKeyDetector(keys: [.rightOption], delayedKeys: [.rightOption])
        _ = detector.handle(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: TalkKey.rightOption.downFlag.union(.maskAlternate), at: .now)
        #expect(detector.setKeys([.rightOption, .rightCommand], delayedKeys: [.rightCommand]) == nil)
        #expect(detector.phase == .arming(.rightOption))
        #expect(detector.delayedKeys == [.rightCommand])
        #expect(detector.waitsBeforeRecording(.rightOption) == false)
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
        let keySets: [Set<TalkKey>] = [[.rightControl], [.fn], [.leftCommand], [.rightControl, .fn], [.leftControl, .rightOption], [.rightControl, .rightOption], Set(TalkKey.allCases)]
        // Every other seed has right Option wait as the translation key does.
        let delayed: Set<TalkKey> = seed.isMultiple(of: 2) ? [.rightOption] : []
        var random = TalkKeyDetectorTests.SplitMix(state: seed)
        var down = Array(repeating: false, count: modifiers.count)
        var detector = TalkKeyDetector(keys: Set(keySets[Int(seed) % keySets.count].map(Hotkey.key)), delayedKeys: Set(delayed.map(Hotkey.key)))
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
                feed(detector.setKeys(Set(keySets[Int(random.next() % UInt64(keySets.count))].map(Hotkey.key)), delayedKeys: Set(delayed.map(Hotkey.key))))
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
