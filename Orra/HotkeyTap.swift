import AppKit
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
/// access is gone. A tap the system switched off is never switched back on,
/// see `handle(type:keyCode:flags:)`.
///
/// Mouse clicks do not go through the tap, so they never wait for Orra. While the tap is
/// installed, a global NSEvent monitor observes mouse button presses instead. It cannot
/// delay or change them, and for mouse events it needs no permission.
final class HotkeyTap {
    /// Creates the event tap and the click monitor for a HotkeyTap and switches them on.
    /// Returns what removes both again, or nil when the system refuses the tap, which
    /// means Orra does not have Accessibility access. A closure, so tests never install a
    /// real tap. The app uses `installLive`.
    typealias Install = @MainActor (HotkeyTap) -> Remove?
    /// Removes an installed tap. True when the system has already switched it off, so it
    /// does not need switching off again.
    typealias Remove = @MainActor (_ systemSwitchedOff: Bool) -> Void

    private let install: Install
    private let onEvent: (PushToTalkStateMachine.Event) -> Void
    private let onSwitchedOff: (CGEventType) -> Void
    private var detector: TalkKeyDetector
    /// Removes the installed tap. Nil while no tap is installed.
    private var removeInstalled: Remove?

    /// - Parameters:
    ///   - install: Creates the tap, see `Install`.
    ///   - onEvent: Receives the push to talk events.
    ///   - onSwitchedOff: Called after the system switched the tap off and the tap removed
    ///     itself, with the reason the system gave.
    init(
        keys: Set<TalkKey>,
        install: @escaping Install,
        onEvent: @escaping (PushToTalkStateMachine.Event) -> Void,
        onSwitchedOff: @escaping (CGEventType) -> Void = { _ in }
    ) {
        detector = TalkKeyDetector(keys: keys)
        self.install = install
        self.onEvent = onEvent
        self.onSwitchedOff = onSwitchedOff
    }

    /// Switches to other talk keys at once. Ends a hold of a key that is no longer one.
    func setKeys(_ keys: Set<TalkKey>) {
        if let event = detector.setKeys(keys) {
            onEvent(event)
        }
    }

    var isInstalled: Bool { removeInstalled != nil }

    /// Creates and enables the tap. Returns false when the system refuses, which
    /// means Orra does not have Accessibility access.
    func start() -> Bool {
        if isInstalled { return true }
        guard let remove = install(self) else {
            return false
        }
        removeInstalled = remove
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
    /// - Parameter systemSwitchedOff: True when the system has already switched the tap
    ///   off, so it is only removed.
    func stop(systemSwitchedOff: Bool = false) {
        guard let removeInstalled else { return }
        self.removeInstalled = nil
        removeInstalled(systemSwitchedOff)
        if let event = detector.reset() {
            onEvent(event)
        }
    }

    /// Handles one event from the tap. Returns true to swallow it. Internal so tests can
    /// feed it events without a tap.
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switched the tap off and events were missed, possibly the
            // release of a hold, so start over. The system is reported to do this again
            // and again once Accessibility access is gone, while AXIsProcessTrusted can
            // still answer yes from its cache. So the tap never switches itself back on.
            // It removes itself, and the owner installs a new tap later, which the system
            // refuses without access.
            stop(systemSwitchedOff: true)
            onSwitchedOff(type)
            return false
        default:
            let decision = detector.handle(type: type, keyCode: keyCode, flags: flags)
            if let event = decision.event {
                onEvent(event)
            }
            return decision.swallow
        }
    }

    /// The real tap: an active tap at the session level for key down and flags changed
    /// events on the main run loop, and the click monitor.
    static func installLive(_ tap: HotkeyTap) -> Remove? {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(tap).toOpaque()
        ) else {
            return nil
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        let clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { @Sendable [weak tap] _ in
            Task { @MainActor in
                tap?.clickDuringHold()
            }
        }
        return { systemSwitchedOff in
            // Switching a tap off waits for the WindowServer's reply on the main thread.
            // A tap the system switched off needs no second call, which matters because
            // the system does that when it finds the main thread slow. Releasing the tap
            // still makes one such call.
            if !systemSwitchedOff {
                CGEvent.tapEnable(tap: port, enable: false)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(port)
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
            }
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
