import CoreGraphics
import Testing
@testable import Orra

/// Drives HotkeyTap without installing a tap, so no event is watched and no prompt shows.
@MainActor
struct HotkeyTapTests {
    static let rightControlDown = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)

    @Test func removingTheHeldKeyEndsTheRecording() {
        var events: [PushToTalkStateMachine.Event] = []
        let tap = HotkeyTap(keys: [.rightControl, .fn]) { events.append($0) }
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown) == false)
        #expect(events == [.pressed(isRepeat: false)])
        tap.setKeys([.fn])
        #expect(events == [.pressed(isRepeat: false), .cancelled])
    }

    @Test func aClickEndsARightControlHold() {
        var events: [PushToTalkStateMachine.Event] = []
        let tap = HotkeyTap(keys: [.rightControl]) { events.append($0) }
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown)
        tap.clickDuringHold()
        #expect(events == [.pressed(isRepeat: false), .cancelled])
        // The release that follows passes through and sends nothing.
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: []) == false)
        #expect(events == [.pressed(isRepeat: false), .cancelled])
    }

    @Test func onlyFnIsSwallowed() {
        let tap = HotkeyTap(keys: [.rightControl, .fn]) { _ in }
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn))
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: []))
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.rightControlDown) == false)
        #expect(tap.handle(type: .keyDown, keyCode: 8, flags: Self.rightControlDown) == false)
    }
}
