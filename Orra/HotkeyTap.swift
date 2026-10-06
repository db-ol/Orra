import AppKit
import ApplicationServices
import CoreGraphics

/// Owns the event tap that watches the keyboard for a hold of a talk key.
///
/// This is an active tap at the session level, so it can
/// swallow fn's own events. The system only creates it once Orra has
/// Accessibility access. The tap sees key down and flags changed events and
/// never stores or logs which key was pressed.
///
/// The tap runs on the main run loop, so every key press on the Mac waits for
/// the main thread. Never block the main thread while the tap is installed.
///
/// Revoking Accessibility access while an active tap is installed can freeze
/// keyboard and mouse input on recent macOS versions (Apple Developer Forums
/// thread 844416). PushToTalkController removes the tap when it learns that
/// access is gone, and the tap is never switched back on without access.
///
/// Mouse clicks do not go through the tap, so they never wait for Orra. While the tap is
/// installed, a global NSEvent monitor observes mouse button presses instead. It cannot
/// delay or change them, and for mouse events it needs no permission.
final class HotkeyTap {
    private let onEvent: (PushToTalkStateMachine.Event) -> Void
    private var detector: TalkKeyDetector
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clickMonitor: Any?

    init(keys: Set<TalkKey>, onEvent: @escaping (PushToTalkStateMachine.Event) -> Void) {
        detector = TalkKeyDetector(keys: keys)
        self.onEvent = onEvent
    }

    /// Switches to other talk keys at once. Ends a hold of a key that is no longer one.
    func setKeys(_ keys: Set<TalkKey>) {
        if let event = detector.setKeys(keys) {
            onEvent(event)
        }
    }

    var isInstalled: Bool { machPort != nil }

    /// Creates and enables the tap. Returns false when the system refuses, which
    /// means Orra does not have Accessibility access.
    func start() -> Bool {
        if machPort != nil { return true }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        machPort = port
        runLoopSource = source
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.clickDuringHold()
            }
        }
        return true
    }

    /// A mouse button went down. Ends a hold of a key that modifies clicks, such as right
    /// Control, whose click opens a context menu. Internal so tests can call it.
    func clickDuringHold() {
        if let event = detector.cancelForClick() {
            onEvent(event)
        }
    }

    /// Disables and removes the tap. Ends a hold in progress.
    func stop() {
        guard let machPort else { return }
        CGEvent.tapEnable(tap: machPort, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(machPort)
        self.machPort = nil
        runLoopSource = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        if let event = detector.reset() {
            onEvent(event)
        }
    }

    /// Handles one event from the tap. Returns true to swallow it. Internal so tests can
    /// feed it events without a tap.
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switched the tap off and events were missed, possibly
            // the release of a hold, so start over. Switch the tap back on only
            // while Orra still has Accessibility access.
            guard AXIsProcessTrusted(), let machPort else {
                stop()
                return false
            }
            if let event = detector.reset() {
                onEvent(event)
            }
            CGEvent.tapEnable(tap: machPort, enable: true)
            return false
        default:
            let decision = detector.handle(type: type, keyCode: keyCode, flags: flags)
            if let event = decision.event {
                onEvent(event)
            }
            return decision.swallow
        }
    }
}

/// The C callback for the tap. It cannot capture context, so the `HotkeyTap`
/// arrives through `userInfo`. The tap's run loop source is on the main run
/// loop, so this runs on the main thread, which `assumeIsolated` checks.
nonisolated private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let swallow = MainActor.assumeIsolated {
        tap.handle(type: type, keyCode: keyCode, flags: flags)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
