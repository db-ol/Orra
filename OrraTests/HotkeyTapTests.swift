import CoreGraphics
import Testing
@testable import Orra

/// Stands in for Accessibility and the system calls behind HotkeyTap. It counts what was
/// asked and never creates a real tap.
@MainActor
final class FakeTapSystem {
    /// What the access check answers. AXIsProcessTrusted can keep saying yes after access
    /// is gone.
    var trusted = true
    /// Whether the system allows a new tap, which it does only with Accessibility access.
    var allowsTap = true
    private(set) var trustChecks = 0
    private(set) var installAttempts = 0
    private(set) var removals = 0
    /// For each removal, whether the system had switched the tap off already.
    private(set) var removedAfterSystemSwitchOff: [Bool] = []
    /// The tap that is installed now, nil while none is.
    private(set) var installed: HotkeyTap?

    func isTrusted() -> Bool {
        trustChecks += 1
        return trusted
    }

    func install(_ tap: HotkeyTap) -> HotkeyTap.Remove? {
        installAttempts += 1
        guard allowsTap else { return nil }
        installed = tap
        return { [self] systemSwitchedOff in
            removals += 1
            removedAfterSystemSwitchOff.append(systemSwitchedOff)
            installed = nil
        }
    }
}

/// Drives HotkeyTap without installing a tap, so no event is watched and no prompt shows.
@MainActor
struct HotkeyTapTests {
    static let rightControlDown = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)

    @Test func removingTheHeldKeyEndsTheRecording() {
        var events: [PushToTalkStateMachine.Event] = []
        let tap = HotkeyTap(keys: [.rightControl, .fn], install: { _ in nil }) { events.append($0) }
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown) == false)
        #expect(events == [.pressed(isRepeat: false)])
        tap.setKeys([.fn])
        #expect(events == [.pressed(isRepeat: false), .cancelled])
    }

    @Test func aClickEndsARightControlHold() {
        var events: [PushToTalkStateMachine.Event] = []
        let tap = HotkeyTap(keys: [.rightControl], install: { _ in nil }) { events.append($0) }
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown)
        tap.clickDuringHold()
        #expect(events == [.pressed(isRepeat: false), .cancelled])
        // The release that follows passes through and sends nothing.
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: []) == false)
        #expect(events == [.pressed(isRepeat: false), .cancelled])
    }

    @Test func onlyFnIsSwallowed() {
        let tap = HotkeyTap(keys: [.rightControl, .fn], install: { _ in nil }) { _ in }
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn))
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: []))
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown) == false)
        #expect(tap.handle(type: .keyDown, keyCode: 8, flags: Self.rightControlDown) == false)
    }

    @Test(arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func aTapTheSystemSwitchedOffEndsTheHoldAndRemovesItself(reason: CGEventType) {
        let system = FakeTapSystem()
        var events: [PushToTalkStateMachine.Event] = []
        var switchedOff: [CGEventType] = []
        let tap = HotkeyTap(keys: [.rightControl], install: system.install) {
            events.append($0)
        } onSwitchedOff: {
            switchedOff.append($0)
        }
        #expect(tap.start())
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown)

        // The event passes through, the hold ends, and the owner learns why.
        #expect(tap.handle(type: reason, keyCode: 0, flags: []) == false)
        #expect(events == [.pressed(isRepeat: false), .cancelled])
        #expect(switchedOff == [reason])
        // The tap is gone and did not switch itself back on. It was not switched off a
        // second time, which would wait on the WindowServer.
        #expect(tap.isInstalled == false)
        #expect(system.removals == 1)
        #expect(system.removedAfterSystemSwitchOff == [true])
        #expect(system.installAttempts == 1)
        #expect(system.installed == nil)

        // Only the owner installs a new tap.
        #expect(tap.start())
        #expect(system.installAttempts == 2)
        #expect(tap.isInstalled)
    }

    @Test func stoppingAnInstalledTapSwitchesItOff() {
        let system = FakeTapSystem()
        let tap = HotkeyTap(keys: [.rightControl], install: system.install) { _ in }
        #expect(tap.start())
        tap.stop()
        #expect(tap.isInstalled == false)
        #expect(system.removedAfterSystemSwitchOff == [false])
        // Stopping again does nothing.
        tap.stop()
        #expect(system.removals == 1)
    }

    // MARK: Timers, hands free and choosing a key

    /// A wait that never ends, so only the test fires timers.
    static let neverFires: HotkeyTap.Wait = { _ in
        try? await Task.sleep(for: .seconds(3600))
    }

    @Test func aLeftKeyStartsAHoldWhenItsTimerFires() {
        var events: [PushToTalkStateMachine.Event] = []
        let tap = HotkeyTap(keys: [.leftCommand], install: { _ in nil }, wait: Self.neverFires) { events.append($0) }
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: flags) == false)
        #expect(events.isEmpty)
        tap.fireTimer()
        #expect(events == [.pressed(isRepeat: false)])
        // A timer that already fired does nothing more.
        tap.fireTimer()
        #expect(events == [.pressed(isRepeat: false)])
    }

    @Test func aLeftKeyShortcutCancelsItsTimer() {
        var events: [PushToTalkStateMachine.Event] = []
        let tap = HotkeyTap(keys: [.leftCommand], install: { _ in nil }, wait: Self.neverFires) { events.append($0) }
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: flags)
        #expect(tap.handle(type: .keyDown, keyCode: 8, flags: flags) == false)
        tap.fireTimer()
        #expect(events.isEmpty)
    }

    @Test func aTapsWindowEndsWhenItsTimerFires() {
        var events: [PushToTalkStateMachine.Event] = []
        let tap = HotkeyTap(keys: [.rightControl], install: { _ in nil }, wait: Self.neverFires) { events.append($0) }
        let start = ContinuousClock.now
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown, at: start)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: [], at: start.advanced(by: .milliseconds(50)))
        #expect(events == [.pressed(isRepeat: false), .tapped])
        tap.fireTimer()
        #expect(events == [.pressed(isRepeat: false), .tapped, .cancelled])
    }

    @Test func theRealWaitFiresTheWindow() async throws {
        var events: [PushToTalkStateMachine.Event] = []
        let tap = HotkeyTap(keys: [.rightControl], install: { _ in nil }) { events.append($0) }
        let start = ContinuousClock.now
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown, at: start)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: [], at: start)
        for _ in 0..<400 where events.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(events == [.pressed(isRepeat: false), .tapped, .cancelled])
    }
}

