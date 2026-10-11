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
///
/// The detector has no clock. The tap passes the time each event arrived, and runs the
/// one timer the detector asks for at a time, for a left hand key's delay or a tap's
/// double press window, as a task on the main actor that never blocks.
final class HotkeyTap {
    /// Creates the event tap and the click monitor for a HotkeyTap and switches them on.
    /// Returns what removes both again, or nil when the system refuses the tap, which
    /// means Orra does not have Accessibility access. A closure, so tests never install a
    /// real tap. The app uses `installLive`.
    typealias Install = @MainActor (HotkeyTap) -> Remove?
    /// Removes an installed tap. True when the system has already switched it off, so it
    /// does not need switching off again.
    typealias Remove = @MainActor (_ systemSwitchedOff: Bool) -> Void

    /// Waits for a timer. Tests pass one that never returns and fire timers themselves.
    typealias Wait = @MainActor (Duration) async -> Void

    private let install: Install
    private let onEvent: (PushToTalkStateMachine.Event) -> Void
    private let onSwitchedOff: (CGEventType) -> Void
    private let wait: Wait
    private var detector: TalkKeyDetector
    /// Removes the installed tap. Nil while no tap is installed.
    private var removeInstalled: Remove?
    /// The running timer and the detector generation it was started for.
    private var timerTask: Task<Void, Never>?
    private var timerGeneration: Int?

    /// - Parameters:
    ///   - install: Creates the tap, see `Install`.
    ///   - onEvent: Receives the push to talk events.
    ///   - onSwitchedOff: Called after the system switched the tap off and the tap removed
    ///     itself, with the reason the system gave.
    ///   - handsFree: Whether a double press starts a hands free dictation.
    ///   - wait: Waits for a timer, see `Wait`.
    init(
        keys: Set<TalkKey>,
        handsFree: Bool = true,
        install: @escaping Install,
        wait: @escaping Wait = { try? await Task.sleep(for: $0) },
        onEvent: @escaping (PushToTalkStateMachine.Event) -> Void,
        onSwitchedOff: @escaping (CGEventType) -> Void = { _ in }
    ) {
        detector = TalkKeyDetector(keys: keys, handsFreeEnabled: handsFree)
        self.install = install
        self.wait = wait
        self.onEvent = onEvent
        self.onSwitchedOff = onSwitchedOff
    }

    /// Switches to other talk keys at once. Ends a hold or a hands free dictation of a key
    /// that is no longer one.
    func setKeys(_ keys: Set<TalkKey>) {
        let event = detector.setKeys(keys)
        afterDetectorChange(event)
    }

    /// Turns double press for hands free on or off.
    func setHandsFree(_ on: Bool) {
        let event = detector.setHandsFreeEnabled(on)
        afterDetectorChange(event)
    }

    /// The owner tells that no hands free dictation runs, see
    /// `TalkKeyDetector.endHandsFree()`.
    func endHandsFree() {
        detector.endHandsFree()
        updateTimer()
    }

    /// The talk key the current press or dictation is about, if any.
    var activeKey: TalkKey? {
        detector.phase.key
    }

    /// Sends the event, if any, and starts or stops the timer the detector asks for.
    private func afterDetectorChange(_ event: PushToTalkStateMachine.Event?) {
        if let event {
            onEvent(event)
        }
        updateTimer()
    }

    private func updateTimer() {
        guard let timer = detector.timer else {
            timerTask?.cancel()
            timerTask = nil
            timerGeneration = nil
            return
        }
        let generation = detector.generation
        guard timerGeneration != generation else { return }
        timerTask?.cancel()
        timerGeneration = generation
        timerTask = Task { [weak self, wait] in
            await wait(timer.duration)
            guard !Task.isCancelled else { return }
            self?.fireTimer(generation: generation)
        }
    }

    /// The timer started for `generation` fired. Internal so tests can fire it.
    func fireTimer(generation: Int? = nil) {
        guard let generation = generation ?? timerGeneration else { return }
        if timerGeneration == generation {
            timerTask = nil
            timerGeneration = nil
        }
        afterDetectorChange(detector.timerFired(generation: generation))
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
        afterDetectorChange(detector.cancelForClick())
    }

    /// Disables and removes the tap. Ends a hold in progress.
    /// - Parameter systemSwitchedOff: True when the system has already switched the tap
    ///   off, so it is only removed.
    func stop(systemSwitchedOff: Bool = false) {
        guard let removeInstalled else { return }
        self.removeInstalled = nil
        removeInstalled(systemSwitchedOff)
        afterDetectorChange(detector.reset())
    }

    /// Handles one event from the tap. Returns true to swallow it. Internal so tests can
    /// feed it events without a tap.
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, at now: ContinuousClock.Instant = .now) -> Bool {
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
            let decision = detector.handle(type: type, keyCode: keyCode, flags: flags, at: now)
            afterDetectorChange(decision.event)
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
    let now = ContinuousClock.now
    let swallow = MainActor.assumeIsolated {
        tap.handle(type: type, keyCode: keyCode, flags: flags, at: now)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
